#!/usr/bin/env bash
#
# setup-github-multi-account.sh
# ----------------------------------------------------------------
# 在 macOS 上为 GitHub 多账号做配置(可重复执行,逐个新增账号):
#   1. 为新增账号生成独立 SSH key(已存在则跳过,绝不覆盖)
#   2. 在 ~/.ssh/config 添加 github.com-<GitHub用户名> 别名
#   3. 配置 git includeIf 按目录自动切换 commit 身份
#   4. 把新增账号 key 加载到 ssh-agent + macOS Keychain
#   5. 引导通过 gh CLI 登录新增账号,并把公钥上传到 GitHub
#
# 对已有配置的处理:
#   - 运行前先探测现有配置(gh 登录账号、git global name/email、常见 SSH key
#     位置、以及之前脚本生成的 ~/.gitconfig-<GitHub用户名>),作为默认值填入
#     交互提示,直接按回车即可沿用,需要改才手输
#   - 所有要修改的文件先打时间戳备份(.bak.YYYYMMDD_HHMMSS)
#   - ~/.ssh/config 和 ~/.gitconfig 用 marker 块管理,重复执行不会累积
#   - 已存在的 SSH 私钥绝不会被重新生成
# ----------------------------------------------------------------

set -euo pipefail

# ---------- 辅助 ----------

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
info()  { printf "%s[INFO]%s %s\n"  "$BLUE"   "$NC" "$*"; }
ok()    { printf "%s[ OK ]%s %s\n"  "$GREEN"  "$NC" "$*"; }
warn()  { printf "%s[WARN]%s %s\n"  "$YELLOW" "$NC" "$*"; }
err()   { printf "%s[ERR ]%s %s\n"  "$RED"    "$NC" "$*" >&2; }

MARKER_BEGIN="# >>> github-multi-account >>>"
MARKER_END="# <<< github-multi-account <<<"

backup_file() {
    local f="$1"
    if [ -f "$f" ]; then
        local bak="${f}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$f" "$bak"
        info "已备份 $f → $bak"
    fi
}

read_or_exit() {
    local prompt="$1" out_var="$2" value=""
    read -r -p "$prompt" value
    local value_upper=""
    value_upper="$(printf '%s' "$value" | tr '[:lower:]' '[:upper:]')"
    if [ "$value" = $'\e' ] || [ "$value" = "^[" ] || [ "$value_upper" = "ESC" ]; then
        echo
        warn "检测到 ESC，已退出脚本。"
        exit 0
    fi
    printf -v "$out_var" '%s' "$value"
}

confirm() {
    local ans
    read_or_exit "$1 [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

ask() {
    # 提示走 stderr(read -p 自带),只有最终值走 stdout,方便 $() 捕获
    local prompt="$1" default="${2:-}" value
    if [ -n "$default" ]; then
        read_or_exit "$prompt [$default]: " value
        printf '%s' "${value:-$default}"
    else
        while true; do
            read_or_exit "$prompt: " value
            if [ -n "$value" ]; then
                printf '%s' "$value"
                return
            fi
            warn "不能为空,请重新输入" >&2
        done
    fi
}

# 删掉文件里一对 marker 之间的内容(含 marker 本身),用于幂等替换
remove_marker_block() {
    local f="$1"
    [ -f "$f" ] || return 0
    awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
        $0 == b { skip=1; next }
        $0 == e { skip=0; next }
        !skip
    ' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
}

dedupe_lines() {
    printf "%s\n" "$@" | awk 'NF && !seen[$0]++'
}

cfg_path_by_alias() {
    local alias="$1" user
    user="${alias#github.com-}"
    if [ "$alias" = "github.com-personal" ]; then
        printf '%s' "$HOME/.gitconfig-personal"
    elif [ "$alias" = "github.com-work" ]; then
        printf '%s' "$HOME/.gitconfig-work"
    else
        printf '%s' "$HOME/.gitconfig-${user}"
    fi
}

resolve_cfg_for_user() {
    local user="$1" c n
    for c in "$HOME/.gitconfig-${user}" "$HOME/.gitconfig-personal" "$HOME/.gitconfig-work"; do
        [ -f "$c" ] || continue
        n="$(git config -f "$c" --get user.name 2>/dev/null || true)"
        [ -n "$n" ] && [ "$n" = "$user" ] && { printf '%s' "$c"; return; }
    done
    printf '%s' "$HOME/.gitconfig-${user}"
}

detect_managed_accounts() {
    local alias user gh_user cfg email name key dir i found existing_alias
    EXISTING_ALIASES=()
    EXISTING_USERS=()
    EXISTING_CFGS=()
    EXISTING_NAMES=()
    EXISTING_EMAILS=()
    EXISTING_KEYS=()
    EXISTING_DIRS=()

    while IFS= read -r alias; do
        [ -z "$alias" ] && continue
        user="${alias#github.com-}"
        cfg="$(cfg_path_by_alias "$alias")"
        [ ! -f "$cfg" ] && cfg="$(resolve_cfg_for_user "$user")"
        name="$(git config -f "$cfg" --get user.name 2>/dev/null || true)"
        gh_user=""
        if [ "$alias" = "github.com-personal" ] || [ "$alias" = "github.com-work" ]; then
            gh_user="$(detect_rewrite_user_for_alias "$alias")"
            [ -z "$gh_user" ] && gh_user="$name"
            [ -n "$gh_user" ] && user="$gh_user"
        fi
        email="$(git config -f "$cfg" --get user.email 2>/dev/null || true)"
        key="$(extract_identityfile_for_host "$alias")"
        dir="$(extract_gitdir_for_cfg_path "$cfg")"
        found=0
        for i in "${!EXISTING_USERS[@]}"; do
            if [ "$user" = "${EXISTING_USERS[$i]}" ]; then
                found=1
                existing_alias="${EXISTING_ALIASES[$i]}"
                if { [ "$existing_alias" = "github.com-personal" ] || [ "$existing_alias" = "github.com-work" ]; } \
                   && [ "$alias" = "github.com-${user}" ]; then
                    EXISTING_ALIASES[$i]="$alias"
                    EXISTING_CFGS[$i]="$cfg"
                    EXISTING_NAMES[$i]="$name"
                    EXISTING_EMAILS[$i]="$email"
                    EXISTING_KEYS[$i]="$key"
                    EXISTING_DIRS[$i]="$dir"
                fi
                break
            fi
        done
        if [ "$found" = "0" ]; then
            EXISTING_ALIASES+=("$alias")
            EXISTING_USERS+=("$user")
            EXISTING_CFGS+=("$cfg")
            EXISTING_NAMES+=("$name")
            EXISTING_EMAILS+=("$email")
            EXISTING_KEYS+=("$key")
            EXISTING_DIRS+=("$dir")
        fi
    done < <(awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
        $0==b {inblk=1; next}
        $0==e {inblk=0; next}
        inblk && $1=="Host" && $2 ~ /^github\.com-/ { print $2 }
    ' "$HOME/.ssh/config" 2>/dev/null || true)
}

# ---------- 检查 ----------

check_deps() {
    local mode="${1:-setup}"
    local missing=()
    local deps=()
    if [ "$mode" = "delete" ] || [ "$mode" = "view" ]; then
        deps=(git awk)
    else
        deps=(git gh ssh-keygen ssh-add awk)
    fi
    for cmd in "${deps[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        err "缺少命令: ${missing[*]}"
        err "请先安装:brew install git gh"
        exit 1
    fi
    if [ "$(uname)" != "Darwin" ]; then
        warn "当前不是 macOS,Keychain 相关功能会自动降级。"
    fi
}

# ---------- 探测已有配置 ----------

detect_existing() {
    info "探测现有配置..."

    # 1) gh 已登录的账号列表
    DETECTED_GH_ACCOUNTS=()
    DETECTED_GH_INVALID_ACCOUNTS=()
    if command -v gh >/dev/null 2>&1; then
        while IFS= read -r line; do
            local acc=""
            acc="$(printf '%s\n' "$line" | grep -oE 'account [A-Za-z0-9][A-Za-z0-9_-]*' | awk '{print $2}' || true)"
            [ -z "$acc" ] && continue
            if printf '%s\n' "$line" | grep -q "Failed to log in"; then
                DETECTED_GH_INVALID_ACCOUNTS+=("$acc")
            else
                DETECTED_GH_ACCOUNTS+=("$acc")
            fi
        done < <(gh auth status 2>&1 || true)
        # 去重
        if [ ${#DETECTED_GH_ACCOUNTS[@]} -gt 0 ]; then
            local deduped_accounts=()
            while IFS= read -r acc; do
                [ -n "$acc" ] && deduped_accounts+=("$acc")
            done < <(dedupe_lines "${DETECTED_GH_ACCOUNTS[@]}")
            DETECTED_GH_ACCOUNTS=("${deduped_accounts[@]}")
        fi
        if [ ${#DETECTED_GH_INVALID_ACCOUNTS[@]} -gt 0 ]; then
            local deduped_invalid_accounts=()
            while IFS= read -r acc; do
                [ -n "$acc" ] && deduped_invalid_accounts+=("$acc")
            done < <(dedupe_lines "${DETECTED_GH_INVALID_ACCOUNTS[@]}")
            DETECTED_GH_INVALID_ACCOUNTS=("${deduped_invalid_accounts[@]}")
        fi
    fi

    # 2) git 全局 name / email
    DETECTED_GIT_NAME="$(git config --global --get user.name  2>/dev/null || true)"
    DETECTED_GIT_EMAIL="$(git config --global --get user.email 2>/dev/null || true)"

    # 3) 常见 SSH key 位置
    DETECTED_KEYS=()
    for k in \
        "$HOME/.ssh/id_ed25519_personal" \
        "$HOME/.ssh/id_ed25519_work" \
        "$HOME/.ssh/id_ed25519" \
        "$HOME/.ssh/id_rsa" \
        "$HOME/.ssh/id_ecdsa"
    do
        [ -f "$k" ] && DETECTED_KEYS+=("$k")
    done

    # 4) 之前脚本生成的子 gitconfig(兼容旧版 personal/work)
    PREV_PERSONAL_NAME=""; PREV_PERSONAL_EMAIL=""
    PREV_WORK_NAME="";     PREV_WORK_EMAIL=""
    if [ -f "$HOME/.gitconfig-personal" ]; then
        PREV_PERSONAL_NAME=$(git config  -f "$HOME/.gitconfig-personal" --get user.name  2>/dev/null || true)
        PREV_PERSONAL_EMAIL=$(git config -f "$HOME/.gitconfig-personal" --get user.email 2>/dev/null || true)
    fi
    if [ -f "$HOME/.gitconfig-work" ]; then
        PREV_WORK_NAME=$(git config  -f "$HOME/.gitconfig-work" --get user.name  2>/dev/null || true)
        PREV_WORK_EMAIL=$(git config -f "$HOME/.gitconfig-work" --get user.email 2>/dev/null || true)
    fi

    # 5) 当前由脚本管理的账号(从 marker block + includeIf 反推)
    detect_managed_accounts

    # 6) 展示检测结果
    echo
    echo "----------------------------------------------------------------"
    echo "  检测到的现有配置"
    echo "----------------------------------------------------------------"
    if [ ${#DETECTED_GH_ACCOUNTS[@]} -gt 0 ]; then
        echo "  gh 可用账号     : ${DETECTED_GH_ACCOUNTS[*]}"
    else
        echo "  gh 可用账号     : (无)"
    fi
    if [ ${#DETECTED_GH_INVALID_ACCOUNTS[@]} -gt 0 ]; then
        echo "  gh 失效账号     : ${DETECTED_GH_INVALID_ACCOUNTS[*]}"
    fi
    echo "  git user.name   : ${DETECTED_GIT_NAME:-(未设置)}"
    echo "  git user.email  : ${DETECTED_GIT_EMAIL:-(未设置)}"
    if [ ${#DETECTED_KEYS[@]} -gt 0 ]; then
        echo "  现有 SSH key    :"
        for k in "${DETECTED_KEYS[@]}"; do echo "                    $k"; done
    else
        echo "  现有 SSH key    : (无)"
    fi
    if [ ${#EXISTING_USERS[@]} -gt 0 ]; then
        local i
        echo "  脚本已管理账号  :"
        for i in "${!EXISTING_USERS[@]}"; do
            echo "                    ${EXISTING_USERS[$i]} <${EXISTING_EMAILS[$i]:-(未识别)}>"
        done
    elif [ -n "${PREV_PERSONAL_NAME}${PREV_WORK_NAME}" ]; then
        echo "  上次脚本结果    :"
        [ -n "$PREV_PERSONAL_EMAIL" ] && echo "                    账号1 → $PREV_PERSONAL_NAME <$PREV_PERSONAL_EMAIL>"
        [ -n "$PREV_WORK_EMAIL"     ] && echo "                    账号2 → $PREV_WORK_NAME <$PREV_WORK_EMAIL>"
    fi
    echo "----------------------------------------------------------------"
    echo "下面提示里 [方括号] 内就是默认值,直接回车即接受,需要改才手输。"
    echo
}

choose_mode() {
    local m
    echo "================================================================"
    echo "  运行模式"
    echo "================================================================"
    echo "  1) 新增账号(可重复执行,支持多账号)"
    echo "  2) 删除某一个账号的配置"
    echo "  3) 查看当前配置(只读)"
    read_or_exit "请选择 [1/2/3]: " m
    case "$m" in
        2) MODE="delete" ;;
        3) MODE="view" ;;
        *) MODE="setup" ;;
    esac
}

view_current_config() {
    local i user alias cfg email name dir key
    echo "================================================================"
    echo "  当前配置(只读)"
    echo "================================================================"
    if [ ${#EXISTING_USERS[@]} -eq 0 ]; then
        echo "未检测到由本脚本管理的账号配置。"
        return 0
    fi
    for i in "${!EXISTING_USERS[@]}"; do
        user="${EXISTING_USERS[$i]}"
        alias="${EXISTING_ALIASES[$i]}"
        cfg="${EXISTING_CFGS[$i]}"
        name="${EXISTING_NAMES[$i]}"
        email="${EXISTING_EMAILS[$i]}"
        dir="${EXISTING_DIRS[$i]}"
        key="${EXISTING_KEYS[$i]}"
        echo
        echo "账号: $user"
        echo "  Host 别名   : ${alias:-(未识别)}"
        echo "  gitconfig   : ${cfg:-(未识别)}"
        echo "  Git 显示名  : ${name:-(未识别)}"
        echo "  Git 邮箱    : ${email:-(未识别)}"
        echo "  代码目录    : ${dir:-(未识别)}"
        echo "  SSH 私钥    : ${key:-(未识别)}"
        echo "  URL 改写    : git@github.com:${user}/... -> git@${alias}:${user}/..."
    done
}

# 在数组里找第一个不等于某值的元素
first_other() {
    local exclude="$1"; shift
    local x
    for x in "$@"; do
        [ -n "$x" ] && [ "$x" != "$exclude" ] && { printf '%s' "$x"; return; }
    done
    return 0
}

user_in_existing() {
    local user="$1" i
    for i in "${!EXISTING_USERS[@]}"; do
        [ "$user" = "${EXISTING_USERS[$i]}" ] && return 0
    done
    return 1
}

build_target_accounts() {
    local i alias cfg
    TARGET_USERS=()
    TARGET_NAMES=()
    TARGET_EMAILS=()
    TARGET_DIRS=()
    TARGET_KEYS=()
    TARGET_ALIASES=()
    TARGET_CFGS=()

    for i in "${!EXISTING_USERS[@]}"; do
        alias="${EXISTING_ALIASES[$i]}"
        [ -z "$alias" ] && alias="github.com-${EXISTING_USERS[$i]}"
        cfg="${EXISTING_CFGS[$i]}"
        [ -z "$cfg" ] && cfg="$HOME/.gitconfig-${EXISTING_USERS[$i]}"
        TARGET_USERS+=("${EXISTING_USERS[$i]}")
        TARGET_NAMES+=("${EXISTING_NAMES[$i]:-${EXISTING_USERS[$i]}}")
        TARGET_EMAILS+=("${EXISTING_EMAILS[$i]}")
        TARGET_DIRS+=("${EXISTING_DIRS[$i]}")
        TARGET_KEYS+=("${EXISTING_KEYS[$i]}")
        TARGET_ALIASES+=("$alias")
        TARGET_CFGS+=("$cfg")
    done

    TARGET_USERS+=("$NEW_USER")
    TARGET_NAMES+=("$NEW_NAME")
    TARGET_EMAILS+=("$NEW_EMAIL")
    TARGET_DIRS+=("$NEW_DIR")
    TARGET_KEYS+=("$NEW_KEY")
    TARGET_ALIASES+=("$NEW_ALIAS")
    TARGET_CFGS+=("$NEW_CFG")
}

pick_delete_target() {
    local a idx=0 alias user gh_user cfg email key dir
    DELETE_ALIASES=()
    DELETE_USERS=()
    DELETE_GH_USERS=()

    while IFS= read -r alias; do
        [ -z "$alias" ] && continue
        user="${alias#github.com-}"
        gh_user="$user"
        if [ "$alias" = "github.com-personal" ] || [ "$alias" = "github.com-work" ]; then
            gh_user="$(detect_rewrite_user_for_alias "$alias")"
        fi
        cfg="$HOME/.gitconfig-${user}"
        if [ "$alias" = "github.com-personal" ]; then
            cfg="$HOME/.gitconfig-personal"
        elif [ "$alias" = "github.com-work" ]; then
            cfg="$HOME/.gitconfig-work"
        fi
        email="$(git config -f "$cfg" --get user.email 2>/dev/null || true)"
        key="$(extract_identityfile_for_host "$alias")"
        dir="$(extract_gitdir_for_cfg_path "$cfg")"
        idx=$((idx+1))
        DELETE_ALIASES+=("$alias")
        DELETE_USERS+=("$user")
        DELETE_GH_USERS+=("$gh_user")
        echo "  $idx) ${gh_user:-$user} ($alias)"
        echo "     邮箱 : ${email:-(未识别)}"
        echo "     目录 : ${dir:-(未识别)}"
        echo "     key  : ${key:-(未识别)}"
    done < <(awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
        $0==b {inblk=1; next}
        $0==e {inblk=0; next}
        inblk && $1=="Host" && $2 ~ /^github\.com-/ { print $2 }
    ' "$HOME/.ssh/config" 2>/dev/null || true)

    if [ ${#DELETE_ALIASES[@]} -eq 0 ]; then
        err "未找到可删除的账号配置(未检测到 github.com-<用户名> Host 配置)"
        exit 1
    fi

    echo
    echo "可输入: 序号 / GitHub 用户名 / Host 别名"
    while true; do
        read_or_exit "删除哪个账号配置?: " a
        if [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le "${#DELETE_ALIASES[@]}" ]; then
            DELETE_ALIAS="${DELETE_ALIASES[$((a-1))]}"
            DELETE_USER="${DELETE_USERS[$((a-1))]}"
            DELETE_GH_USER="${DELETE_GH_USERS[$((a-1))]}"
            return
        fi
        for idx in "${!DELETE_ALIASES[@]}"; do
            if [ "$a" = "${DELETE_USERS[$idx]}" ] || [ "$a" = "${DELETE_ALIASES[$idx]}" ] || [ "$a" = "${DELETE_GH_USERS[$idx]}" ]; then
                DELETE_ALIAS="${DELETE_ALIASES[$idx]}"
                DELETE_USER="${DELETE_USERS[$idx]}"
                DELETE_GH_USER="${DELETE_GH_USERS[$idx]}"
                return
            fi
        done
        warn "输入无效,请填序号/用户名/别名"
    done
}

# ---------- 收集输入 ----------

collect_inputs() {
    echo "================================================================"
    echo "  GitHub 多账号配置 (macOS)"
    echo "================================================================"
    info "当前已配置 ${#EXISTING_USERS[@]} 个账号；本次将新增 1 个账号。"
    if [ ${#EXISTING_USERS[@]} -gt 0 ]; then
        local i
        for i in "${!EXISTING_USERS[@]}"; do
            echo "  - ${EXISTING_USERS[$i]} <${EXISTING_EMAILS[$i]:-(未识别)}>"
        done
    fi

    local default_new_user=""
    local candidate
    if [ ${#DETECTED_GH_ACCOUNTS[@]} -gt 0 ]; then
        for candidate in "${DETECTED_GH_ACCOUNTS[@]}"; do
            if ! user_in_existing "$candidate"; then
                default_new_user="$candidate"
                break
            fi
        done
    fi

    echo
    echo "--- 新增账号 ---"
    NEW_USER=$(ask "GitHub 用户名" "$default_new_user")
    if user_in_existing "$NEW_USER"; then
        err "账号 $NEW_USER 已存在。请使用删除模式移除后再重建，或输入其他用户名。"
        exit 1
    fi

    local cfg_by_user="$HOME/.gitconfig-${NEW_USER}"
    local default_name="$NEW_USER"
    local default_email="$DETECTED_GIT_EMAIL"
    local existing_name=""
    local existing_email=""
    if [ -f "$cfg_by_user" ]; then
        existing_name=$(git config -f "$cfg_by_user" --get user.name 2>/dev/null || true)
        existing_email=$(git config -f "$cfg_by_user" --get user.email 2>/dev/null || true)
    fi
    [ -n "$existing_name" ] && default_name="$existing_name"
    [ -z "$existing_name" ] && [ -n "$DETECTED_GIT_NAME" ] && default_name="$DETECTED_GIT_NAME"
    [ -n "$existing_email" ] && default_email="$existing_email"

    NEW_NAME=$(ask "Git 显示名" "$default_name")
    NEW_EMAIL=$(ask "Git 邮箱" "$default_email")
    NEW_DIR=$(ask "代码目录(此目录下的仓库自动用该账号身份)" "$HOME/code/${NEW_USER}")
    NEW_KEY=$(ask "SSH 私钥路径" "$HOME/.ssh/id_ed25519_${NEW_USER}")

    NEW_DIR="${NEW_DIR/#\~/$HOME}"
    NEW_KEY="${NEW_KEY/#\~/$HOME}"
    [[ "$NEW_DIR" != */ ]] && NEW_DIR="${NEW_DIR}/"
    NEW_ALIAS="github.com-${NEW_USER}"
    NEW_CFG="$HOME/.gitconfig-${NEW_USER}"

    local i ed ekey eemail
    for i in "${!EXISTING_USERS[@]}"; do
        ekey="${EXISTING_KEYS[$i]}"
        ed="${EXISTING_DIRS[$i]}"
        eemail="${EXISTING_EMAILS[$i]}"
        [ -n "$ed" ] && [[ "$ed" != */ ]] && ed="${ed}/"
        if [ -n "$ekey" ] && [ "$NEW_KEY" = "$ekey" ]; then
            err "SSH key 路径与已有账号冲突: $ekey"
            exit 1
        fi
        if [ -n "$ed" ] && [ "$NEW_DIR" = "$ed" ]; then
            err "代码目录与已有账号冲突: $ed"
            exit 1
        fi
        if [ -n "$eemail" ] && [ "$NEW_EMAIL" = "$eemail" ]; then
            warn "新账号邮箱与已有账号 ${EXISTING_USERS[$i]} 相同，不推荐。"
            confirm "仍然继续?" || exit 1
            break
        fi
    done

    build_target_accounts

    echo
    info "即将新增账号:"
    echo "  用户名: $NEW_USER"
    echo "  显示名: $NEW_NAME"
    echo "  邮箱  : $NEW_EMAIL"
    echo "  目录  : $NEW_DIR"
    echo "  key   : $NEW_KEY"
    echo "  Host  : $NEW_ALIAS"
    echo
    confirm "确认继续?" || { err "已取消"; exit 1; }
}

# ---------- 实际执行 ----------

setup_ssh_keys() {
    info "=== 1/7 准备 SSH key ==="
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    if [ -f "$NEW_KEY" ]; then
        ok "已存在 $NEW_KEY — 沿用,不重新生成"
    else
        info "生成 $NEW_KEY (ed25519, 无密码;要带密码请 Ctrl-C 后先手动 ssh-keygen)"
        ssh-keygen -t ed25519 -C "$NEW_EMAIL" -f "$NEW_KEY" -N "" -q
        ok "已生成 $NEW_KEY"
    fi
}

setup_ssh_config() {
    info "=== 2/7 配置 ~/.ssh/config ==="
    local cfg="$HOME/.ssh/config"
    touch "$cfg"
    chmod 600 "$cfg"
    backup_file "$cfg"
    remove_marker_block "$cfg"

    {
        printf '\n%s\n' "$MARKER_BEGIN"
        echo "# 由 setup-github-multi-account.sh 生成 — 此 block 会在脚本重跑时被整体替换"
        echo
        local i alias key
        for i in "${!TARGET_USERS[@]}"; do
            alias="${TARGET_ALIASES[$i]}"
            key="${TARGET_KEYS[$i]}"
            [ -z "$alias" ] && continue
            [ -z "$key" ] && continue
            cat <<EOF
Host $alias
  HostName github.com
  User git
  IdentityFile $key
  IdentitiesOnly yes
  AddKeysToAgent yes
  UseKeychain yes

EOF
        done
        printf '%s\n' "$MARKER_END"
    } >> "$cfg"

    ok "已写入 ${#TARGET_USERS[@]} 个 Host 别名"
}

setup_git_config() {
    info "=== 3/7 配置 git (~/.gitconfig 的 includeIf) ==="

    local main="$HOME/.gitconfig"
    backup_file "$NEW_CFG"
    cat > "$NEW_CFG" <<EOF
# 账号身份 — 由 setup-github-multi-account.sh 管理
[user]
    name = $NEW_NAME
    email = $NEW_EMAIL
EOF
    ok "已写入 $NEW_CFG"

    touch "$main"
    backup_file "$main"

    if grep -qE '^\[user\]' "$main" 2>/dev/null; then
        warn "~/.gitconfig 已有 [user] 配置,将保留不动。"
        warn "→ 两个目录之外的仓库仍然会用它作为默认身份。"
        warn "→ 建议受管仓库放进对应账号目录下,由 includeIf 接管。"
    fi

    remove_marker_block "$main"
    {
        printf '\n%s\n' "$MARKER_BEGIN"
        echo "# 按目录自动切换 git 身份 — 由 setup-github-multi-account.sh 管理"
        local i dir cfgp
        for i in "${!TARGET_USERS[@]}"; do
            dir="${TARGET_DIRS[$i]}"
            cfgp="${TARGET_CFGS[$i]}"
            [ -z "$dir" ] && continue
            [ -z "$cfgp" ] && continue
            [[ "$dir" != */ ]] && dir="${dir}/"
            cat <<EOF
[includeIf "gitdir:$dir"]
    path = $cfgp
EOF
        done
        printf '%s\n' "$MARKER_END"
    } >> "$main"

    ok "已写入 includeIf 规则"
}

setup_git_url_rewrite() {
    info "=== 4/7 配置 git URL 自动改写 (insteadOf) ==="

    # 防手滑: 输入 git@github.com:<user>/repo.git 时,自动改写到对应 Host 别名
    local i user alias
    for i in "${!TARGET_USERS[@]}"; do
        user="${TARGET_USERS[$i]}"
        alias="${TARGET_ALIASES[$i]}"
        [ -z "$user" ] && continue
        [ -z "$alias" ] && continue
        git config --global "url.git@${alias}:${user}/.insteadOf" "git@github.com:${user}/"
    done
    ok "已配置/刷新 ${#TARGET_USERS[@]} 个账号的 URL 改写规则"
}

setup_directories() {
    info "=== 5/7 创建代码目录 ==="
    mkdir -p "$NEW_DIR"
    ok "目录就绪:$NEW_DIR"
}

setup_ssh_agent() {
    info "=== 6/7 添加 key 到 ssh-agent + Keychain ==="
    local keychain_flag="--apple-use-keychain"
    if ! ssh-add -h 2>&1 | grep -q -- "--apple-use-keychain"; then
        keychain_flag="-K"
    fi
    eval "$(ssh-agent -s)" >/dev/null 2>&1 || true

    if ssh-add "$keychain_flag" "$NEW_KEY" 2>/dev/null; then
        ok "已加载 $NEW_KEY"
    else
        if ssh-add "$NEW_KEY" 2>/dev/null; then
            ok "已加载 $NEW_KEY (无密码,未写 Keychain)"
        else
            warn "加载 $NEW_KEY 失败,稍后可手动:ssh-add $keychain_flag $NEW_KEY"
        fi
    fi
}

setup_gh_cli() {
    info "=== 7/7 gh CLI 登录 + 上传公钥 ==="
    echo
    echo "下面引导登录新增账号,已登录过会自动跳过。"
    echo

    echo
    info "--- 新增账号 ($NEW_USER) ---"

    if gh auth status 2>&1 | grep -q "account $NEW_USER"; then
        ok "$NEW_USER 已登录,跳过 gh auth login"
    else
        if confirm "现在打开浏览器登录账号 ($NEW_USER)?"; then
            if ! gh auth login --hostname github.com --git-protocol ssh --web; then
                warn "登录失败或被取消,稍后可手动:gh auth login"
                return 0
            fi
        else
            warn "跳过登录"
            return 0
        fi
    fi

    gh auth switch --user "$NEW_USER" >/dev/null 2>&1 || true

    local title="$(scutil --get ComputerName 2>/dev/null || hostname -s)-$NEW_USER"
    if confirm "上传公钥 ${NEW_KEY}.pub 到 $NEW_USER 的 GitHub (title: $title)?"; then
        if gh ssh-key add "${NEW_KEY}.pub" --title "$title"; then
            ok "公钥已上传到 $NEW_USER"
        else
            warn "上传失败(可能 key 已在 GitHub 上,或 token 缺 admin:public_key 权限)"
            warn "可手动到 https://github.com/settings/keys 粘贴 ${NEW_KEY}.pub 内容"
        fi
    fi
}

extract_identityfile_for_host() {
    local alias="$1" cfg="$HOME/.ssh/config"
    [ -f "$cfg" ] || return 0
    awk -v host="$alias" '
        $1=="Host" { inhost=($2==host); next }
        inhost && $1=="IdentityFile" { print $2; exit }
    ' "$cfg"
}

extract_gitdir_for_cfg_path() {
    local cfg_path="$1" main="$HOME/.gitconfig"
    [ -f "$main" ] || return 0
    awk -v target="$cfg_path" '
        /^\[includeIf "gitdir:/ {
            sec=$0
            sub(/^\[includeIf "gitdir:/, "", sec)
            sub(/"\]$/, "", sec)
            curdir=sec
            next
        }
        /^[[:space:]]*path[[:space:]]*=/ {
            p=$0
            sub(/^[[:space:]]*path[[:space:]]*=[[:space:]]*/, "", p)
            if (p==target) { print curdir; exit }
        }
    ' "$main"
}

detect_rewrite_user_for_alias() {
    local alias="$1" line key
    while IFS= read -r line; do
        key="${line%% *}"
        key="${key#url.git@${alias}:}"
        key="${key%.insteadOf}"
        key="${key%/}"
        if [ -n "$key" ]; then
            printf '%s' "$key"
            return
        fi
    done < <(git config --global --get-regexp "^url\\.git@${alias}:.*\\.insteadOf$" 2>/dev/null || true)
}

remove_host_from_marker() {
    local cfg="$HOME/.ssh/config" alias="$1"
    [ -f "$cfg" ] || return 0
    awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" -v target="$alias" '
        $0==b {inblk=1; print; next}
        $0==e {inblk=0; skip=0; print; next}
        !inblk { print; next }
        $1=="Host" {
            if ($2==target) { skip=1; next }
            if (skip) { skip=0 }
            print
            next
        }
        { if (!skip) print }
    ' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
}

remove_includeif_for_cfg_path() {
    local main="$HOME/.gitconfig" cfg_path="$1"
    [ -f "$main" ] || return 0
    awk -v target="$cfg_path" '
        function flush() {
            if (!insec) return
            if (!drop) printf "%s", sec
            sec=""
            insec=0
            drop=0
        }
        /^\[includeIf "gitdir:/ {
            flush()
            insec=1
            sec=$0 ORS
            next
        }
        insec {
            sec=sec $0 ORS
            if ($0 ~ /^[[:space:]]*path[[:space:]]*=/) {
                p=$0
                sub(/^[[:space:]]*path[[:space:]]*=[[:space:]]*/, "", p)
                if (p==target) drop=1
            }
            next
        }
        { print }
        END { flush() }
    ' "$main" > "${main}.tmp" && mv "${main}.tmp" "$main"
}

remove_url_rewrite_by_regex() {
    local regex="$1"
    local key
    while IFS= read -r line; do
        key="${line%% *}"
        [ -n "$key" ] && git config --global --unset-all "$key" || true
    done < <(git config --global --get-regexp "$regex" 2>/dev/null || true)
}

delete_account_config() {
    local user="$1" alias="$2" gh_user="${3:-}"
    local main="$HOME/.gitconfig" ssh_cfg="$HOME/.ssh/config"
    local cfg_path="$HOME/.gitconfig-${user}"
    [ "$alias" = "github.com-personal" ] && cfg_path="$HOME/.gitconfig-personal"
    [ "$alias" = "github.com-work" ] && cfg_path="$HOME/.gitconfig-work"

    info "=== 删除账号配置模式 ==="
    info "将删除: ${gh_user:-$user} ($alias)"
    confirm "确认继续?" || { err "已取消"; exit 1; }

    mkdir -p "$HOME/.ssh"
    touch "$ssh_cfg" "$main"

    backup_file "$ssh_cfg"
    remove_host_from_marker "$alias"

    backup_file "$main"
    remove_includeif_for_cfg_path "$cfg_path"

    backup_file "$cfg_path"
    rm -f "$cfg_path"
    remove_url_rewrite_by_regex "^url\\.git@${alias}:.*\\.insteadOf$"
    remove_url_rewrite_by_regex "^url\\.git@github\\.com-(${user}|personal|work):.*\\.insteadOf$"
    remove_url_rewrite_by_regex "^url\\.git@github\\.com:${user}/\\.insteadOf$"
    ok "已删除 $user 对应配置与 URL 自动改写规则"

    if command -v gh >/dev/null 2>&1 && [ -n "$gh_user" ]; then
        if confirm "同时从 gh CLI 中登出并移除账号 $gh_user ?"; then
            if gh auth logout -h github.com -u "$gh_user"; then
                ok "已从 gh CLI 移除账号 $gh_user"
            else
                warn "gh logout 失败,可手动执行: gh auth logout -h github.com -u $gh_user"
            fi
        fi
    fi

    ok "处理完成。SSH 私钥文件不会被删除。"
}

print_summary() {
    cat <<EOF

================================================================
 🎉 配置完成
================================================================

本次新增账号:
  $NEW_USER <$NEW_EMAIL>
  Host: $NEW_ALIAS
  目录: $NEW_DIR
  key : $NEW_KEY

当前脚本管理账号总数: ${#TARGET_USERS[@]}

常用命令:
  gh auth switch
  gh auth status
  cd $NEW_DIR
  git clone git@$NEW_ALIAS:$NEW_USER/REPO.git

快速验证:
  ssh -T git@$NEW_ALIAS
  cd $NEW_DIR && git config user.email    # → $NEW_EMAIL

备份的旧配置文件在对应路径下以 .bak.YYYYMMDD_HHMMSS 结尾。
脚本可以反复执行,是幂等的。
EOF
}

# ---------- main ----------
MODE="setup"
choose_mode
check_deps "$MODE"
detect_existing

if [ "$MODE" = "delete" ]; then
    pick_delete_target
    delete_account_config "$DELETE_USER" "$DELETE_ALIAS" "$DELETE_GH_USER"
    exit 0
fi

if [ "$MODE" = "view" ]; then
    view_current_config
    exit 0
fi

collect_inputs
setup_ssh_keys
setup_ssh_config
setup_git_config
setup_git_url_rewrite
setup_directories
setup_ssh_agent
setup_gh_cli
print_summary

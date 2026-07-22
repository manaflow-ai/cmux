# cmux shell integration for bash

# Cache which send tool is available to avoid repeated PATH lookups.
_CMUX_SEND_TOOL=""
_cmux_detect_send_tool() {
    if command -v ncat >/dev/null 2>&1; then
        _CMUX_SEND_TOOL=ncat
    elif command -v socat >/dev/null 2>&1; then
        _CMUX_SEND_TOOL=socat
    elif command -v nc >/dev/null 2>&1; then
        _CMUX_SEND_TOOL=nc
    fi
}
# Detection deferred to after _cmux_fix_path (end of file).

_cmux_send() {
    local payload="$1"
    case "$_CMUX_SEND_TOOL" in
        ncat)
            printf '%s\n' "$payload" | ncat -w 1 -U "$CMUX_SOCKET_PATH" --send-only
            ;;
        socat)
            printf '%s\n' "$payload" | socat -T 1 - "UNIX-CONNECT:$CMUX_SOCKET_PATH" >/dev/null 2>&1
            ;;
        nc)
            if printf '%s\n' "$payload" | nc -N -U "$CMUX_SOCKET_PATH" >/dev/null 2>&1; then
                :
            else
                printf '%s\n' "$payload" | nc -w 1 -U "$CMUX_SOCKET_PATH" >/dev/null 2>&1 || true
            fi
            ;;
    esac
}

_cmux_detach_bg() {
    ( "$@" >/dev/null 2>&1 & ) >/dev/null 2>&1
}

_cmux_send_bg() {
    local payload="$1"
    if [[ "${_CMUX_IN_PREEXEC:-}" == "1" ]]; then
        {
            _cmux_send "$payload"
        } >/dev/null 2>&1 &
        disown
        return 0
    fi
    _cmux_detach_bg _cmux_send "$payload"
}

_cmux_start_tracked_bg() {
    local __pid_var="$1"
    shift
    local __pid_file="${TMPDIR:-/tmp}/cmux-bg-pid-$$-${RANDOM:-0}"
    local __pid=""
    (
        "$@" >/dev/null 2>&1 &
        printf '%s\n' "$!" > "$__pid_file"
    )
    if [[ -r "$__pid_file" ]]; then
        IFS= read -r __pid < "$__pid_file" || __pid=""
        /bin/rm -f -- "$__pid_file" >/dev/null 2>&1 || true
    fi
    printf -v "$__pid_var" '%s' "$__pid"
}

_cmux_socket_is_unix() {
    [[ -n "$CMUX_SOCKET_PATH" && -S "$CMUX_SOCKET_PATH" ]]
}

_cmux_relay_cli_path() {
    if [[ -n "${CMUX_BUNDLED_CLI_PATH:-}" && -x "${CMUX_BUNDLED_CLI_PATH}" ]]; then
        printf '%s\n' "${CMUX_BUNDLED_CLI_PATH}"
        return 0
    fi
    command -v cmux 2>/dev/null
}

_cmux_socket_uses_remote_relay() {
    [[ -n "$CMUX_SOCKET_PATH" ]] || return 1
    [[ "$CMUX_SOCKET_PATH" == /* ]] && return 1
    [[ "$CMUX_SOCKET_PATH" == *:* ]] || return 1
    [[ -n "$(_cmux_relay_cli_path)" ]]
}

_cmux_has_port_scan_transport() {
    _cmux_socket_is_unix && return 0
    _cmux_socket_uses_remote_relay
}

_cmux_json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s\n' "$value"
}

_cmux_relay_rpc_bg() {
    local method="$1"
    local params="$2"
    local relay_cli=""
    _cmux_socket_uses_remote_relay || return 1
    relay_cli="$(_cmux_relay_cli_path)" || return 1
    _cmux_detach_bg "$relay_cli" rpc "$method" "$params"
}

_cmux_relay_rpc() {
    local method="$1"
    local params="$2"
    local relay_cli=""
    local response=""
    _cmux_socket_uses_remote_relay || return 1
    # Relay `cmux rpc` exits nonzero on server error. The real remote CLI prints
    # only the JSON result payload on success, while some test stubs return the
    # full `{"ok":...}` envelope. Retry only on explicit `ok:false`.
    relay_cli="$(_cmux_relay_cli_path)" || return 1
    response="$("$relay_cli" rpc "$method" "$params" 2>/dev/null)" || return 1
    response="${response//$'\n'/}"
    response="${response//$'\r'/}"
    [[ "$response" == *'"ok":false'* || "$response" == *'"ok": false'* ]] && return 1
    return 0
}

_cmux_relay_workspace_id() {
    if [[ -n "$CMUX_WORKSPACE_ID" ]]; then
        printf '%s\n' "$CMUX_WORKSPACE_ID"
        return 0
    fi
    [[ -n "$CMUX_TAB_ID" ]] || return 1
    printf '%s\n' "$CMUX_TAB_ID"
}

_cmux_report_tty_via_relay() {
    _cmux_socket_uses_remote_relay || return 1
    local workspace_id=""
    workspace_id="$(_cmux_relay_workspace_id)" || return 1
    [[ -n "$_CMUX_TTY_NAME" ]] || return 1

    local tty_name_json params
    tty_name_json="$(_cmux_json_escape "$_CMUX_TTY_NAME")"
    params="{\"workspace_id\":\"$workspace_id\",\"tty_name\":\"$tty_name_json\""
    if [[ -n "$CMUX_PANEL_ID" ]]; then
        params+=",\"surface_id\":\"$CMUX_PANEL_ID\""
    fi
    params+="}"
    _cmux_relay_rpc "surface.report_tty" "$params"
}

_cmux_report_pwd_via_relay() {
    local pwd="$1"
    _cmux_socket_uses_remote_relay || return 1
    [[ -n "$pwd" ]] || return 1
    local workspace_id=""
    workspace_id="$(_cmux_relay_workspace_id)" || return 1

    local pwd_json params
    pwd_json="$(_cmux_json_escape "$pwd")"
    params="{\"workspace_id\":\"$workspace_id\",\"path\":\"$pwd_json\""
    if [[ -n "$CMUX_PANEL_ID" ]]; then
        params+=",\"surface_id\":\"$CMUX_PANEL_ID\""
    fi
    params+="}"
    _cmux_relay_rpc_bg "surface.report_pwd" "$params"
}

_cmux_report_git_branch_via_relay() {
    local branch="$1"
    _cmux_socket_uses_remote_relay || return 1
    [[ -n "$branch" ]] || return 1
    local workspace_id="" branch_json="" params=""
    workspace_id="$(_cmux_relay_workspace_id)" || return 1
    branch_json="$(_cmux_json_escape "$branch")"
    params="{\"workspace_id\":\"$workspace_id\",\"branch\":\"$branch_json\""
    if [[ -n "${CMUX_PANEL_ID:-}" ]]; then
        params+=",\"surface_id\":\"$CMUX_PANEL_ID\""
    fi
    params+="}"
    _cmux_relay_rpc "surface.report_git_branch" "$params"
}

_cmux_clear_git_branch_via_relay() {
    _cmux_socket_uses_remote_relay || return 1
    local workspace_id="" params=""
    workspace_id="$(_cmux_relay_workspace_id)" || return 1
    params="{\"workspace_id\":\"$workspace_id\""
    if [[ -n "${CMUX_PANEL_ID:-}" ]]; then
        params+=",\"surface_id\":\"$CMUX_PANEL_ID\""
    fi
    params+="}"
    _cmux_relay_rpc "surface.clear_git_branch" "$params"
}

_cmux_report_shell_activity_state_via_relay() {
    local state="$1"
    _cmux_socket_uses_remote_relay || return 1
    [[ -n "$state" ]] || return 1
    local workspace_id="" params=""
    workspace_id="$(_cmux_relay_workspace_id)" || return 1
    params="{\"workspace_id\":\"$workspace_id\",\"state\":\"$state\""
    if [[ -n "${CMUX_PANEL_ID:-}" ]]; then
        params+=",\"surface_id\":\"$CMUX_PANEL_ID\""
    fi
    params+="}"
    _cmux_relay_rpc_bg "surface.report_shell_state" "$params"
}

_cmux_ports_kick_via_relay() {
    local reason="${1:-command}"
    _cmux_socket_uses_remote_relay || return 1
    local workspace_id=""
    workspace_id="$(_cmux_relay_workspace_id)" || return 1
    local params="{\"workspace_id\":\"$workspace_id\",\"reason\":\"$reason\""
    if [[ -n "$CMUX_PANEL_ID" ]]; then
        params+=",\"surface_id\":\"$CMUX_PANEL_ID\""
    fi
    params+="}"
    _cmux_relay_rpc_bg "surface.ports_kick" "$params"
}

_cmux_restore_scrollback_once() {
    local path="${CMUX_RESTORE_SCROLLBACK_FILE:-}"
    [[ -n "$path" ]] || return 0
    unset CMUX_RESTORE_SCROLLBACK_FILE
    local token="${path##*/}"

    builtin printf '\033]1337;CurrentDir=kitty-shell-cwd://%s/.cmux/session-scrollback-replay/%s/start\007' "$HOSTNAME" "$token"

    if [[ -r "$path" ]]; then
        /bin/cat -- "$path" 2>/dev/null || true
        /bin/rm -f -- "$path" >/dev/null 2>&1 || true
    fi

    # Valid kitty-shell-cwd URIs reach Ghostty's PWD action in PTY order. The
    # following real cwd report keeps the private boundary out of title state.
    builtin printf '\033]1337;CurrentDir=kitty-shell-cwd://%s/.cmux/session-scrollback-replay/%s/end\007' "$HOSTNAME" "$token"
    builtin printf '\033]1337;CurrentDir=kitty-shell-cwd://%s%s\007' "$HOSTNAME" "$PWD"
}
_cmux_restore_scrollback_once
_CMUX_CLAUDE_WRAPPER="${_CMUX_CLAUDE_WRAPPER:-}"
_CMUX_GROK_WRAPPER="${_CMUX_GROK_WRAPPER:-}"
_cmux_path_prepend_unique_directory() {
    local directory="$1"
    local current_path="${2-}"
    local skipped_directory="${3-}"
    local result="$directory"
    local rest="$current_path"
    local entry=""
    local has_more=false

    [[ -n "$directory" ]] || {
        printf '%s' "$current_path"
        return 0
    }
    [[ -n "$current_path" ]] || {
        printf '%s' "$directory"
        return 0
    }

    while true; do
        if [[ "$rest" == *:* ]]; then
            entry="${rest%%:*}"
            rest="${rest#*:}"
            has_more=true
        else
            entry="$rest"
            rest=""
            has_more=false
        fi

        if [[ "$entry" != "$directory" && ( -z "$skipped_directory" || "$entry" != "$skipped_directory" ) ]]; then
            result="$result:$entry"
        fi
        [[ "$has_more" == true ]] || break
    done

    printf '%s' "$result"
}
_cmux_install_cli_command_shim() {
    local command_name="$1"
    local wrapper_path="$2"
    local shim_root="${TMPDIR:-/tmp}/cmux-cli-shims/${CMUX_SURFACE_ID:-$$}"
    local shim_path="$shim_root/$command_name"
    local escaped_wrapper="$wrapper_path"

    escaped_wrapper="${escaped_wrapper//\\/\\\\}"
    escaped_wrapper="${escaped_wrapper//\"/\\\"}"
    escaped_wrapper="${escaped_wrapper//\$/\\\$}"
    escaped_wrapper="${escaped_wrapper//\`/\\\`}"

    /bin/mkdir -p "$shim_root" >/dev/null 2>&1 || return 0
    {
        printf '%s\n' '#!/usr/bin/env bash'
        if [[ "$command_name" == "claude" ]]; then
            printf 'cmux_wrapper="%s"\n' "$escaped_wrapper"
            printf '%s\n' 'if [[ ! -x "$cmux_wrapper" && -n "${CMUX_BUNDLED_CLI_PATH:-}" ]]; then'
            printf '%s\n' '    cmux_candidate="$(dirname "$CMUX_BUNDLED_CLI_PATH")/cmux-claude-wrapper"'
            printf '%s\n' '    if [[ -x "$cmux_candidate" ]]; then'
            printf '%s\n' '        cmux_wrapper="$cmux_candidate"'
            printf '%s\n' '    fi'
            printf '%s\n' 'fi'
            printf '%s\n' 'if [[ ! -x "$cmux_wrapper" ]]; then'
            printf '%s\n' '    cmux_cli="$(command -v cmux 2>/dev/null || true)"'
            printf '%s\n' '    if [[ -n "$cmux_cli" ]]; then'
            printf '%s\n' '        cmux_candidate="$(dirname "$cmux_cli")/cmux-claude-wrapper"'
            printf '%s\n' '        if [[ -x "$cmux_candidate" ]]; then'
            printf '%s\n' '            cmux_wrapper="$cmux_candidate"'
            printf '%s\n' '        fi'
            printf '%s\n' '    fi'
            printf '%s\n' 'fi'
            printf 'export CMUX_CLAUDE_WRAPPER_SHIM="%s"\n' "$shim_path"
            printf 'export CMUX_CLAUDE_WRAPPER_SHIM_ROOT="%s"\n' "$shim_root"
            printf '%s\n' 'if [[ -x "$cmux_wrapper" ]]; then'
            printf '%s\n' '    exec "$cmux_wrapper" "$@"'
            printf '%s\n' 'fi'
            printf '%s\n' 'cmux_path_without_shim=""'
            printf '%s\n' 'cmux_old_ifs="$IFS"'
            printf '%s\n' 'IFS=:'
            printf '%s\n' 'for cmux_entry in ${PATH:-}; do'
            printf '%s\n' '    if [[ "$cmux_entry" == "$CMUX_CLAUDE_WRAPPER_SHIM_ROOT" || "$cmux_entry" == */cmux-cli-shims/* || "$cmux_entry" == */cmux-cli-shims ]]; then'
            printf '%s\n' '        continue'
            printf '%s\n' '    fi'
            printf '%s\n' '    if [[ -z "$cmux_path_without_shim" ]]; then'
            printf '%s\n' '        cmux_path_without_shim="$cmux_entry"'
            printf '%s\n' '    else'
            printf '%s\n' '        cmux_path_without_shim="$cmux_path_without_shim:$cmux_entry"'
            printf '%s\n' '    fi'
            printf '%s\n' 'done'
            printf '%s\n' 'IFS="$cmux_old_ifs"'
            printf '%s\n' 'export PATH="$cmux_path_without_shim"'
            printf '%s\n' 'exec claude "$@"'
        else
            printf 'exec "%s" "$@"\n' "$escaped_wrapper"
        fi
    } >"$shim_path" 2>/dev/null || return 0
    /bin/chmod 0700 "$shim_path" >/dev/null 2>&1 || return 0

    if [[ "$command_name" == "claude" ]]; then
        export CMUX_CLAUDE_WRAPPER_SHIM="$shim_path"
        export CMUX_CLAUDE_WRAPPER_SHIM_ROOT="$shim_root"
    fi

    PATH="$(_cmux_path_prepend_unique_directory "$shim_root" "${PATH-}")"
    hash -r >/dev/null 2>&1 || true
}
_cmux_claude_wrapper_command() {
    if [[ -x "${CMUX_CLAUDE_WRAPPER_SHIM:-}" ]]; then
        "$CMUX_CLAUDE_WRAPPER_SHIM" "$@"
    elif [[ -x "${_CMUX_CLAUDE_WRAPPER:-}" ]]; then
        "$_CMUX_CLAUDE_WRAPPER" "$@"
    else
        command claude "$@"
    fi
}
_cmux_install_cli_wrapper() {
    local command_name="$1"
    local wrapper_variable="$2"
    local wrapper_file="${3:-$command_name}"
    local integration_dir="${CMUX_SHELL_INTEGRATION_DIR:-}"
    local existing_type=""
    [[ -n "$integration_dir" ]] || return 0

    integration_dir="${integration_dir%/}"
    local bundle_dir="${integration_dir%/shell-integration}"
    local wrapper_path="$bundle_dir/bin/$wrapper_file"
    [[ -x "$wrapper_path" ]] || return 0

    existing_type="$(type -t "$command_name" 2>/dev/null || true)"
    printf -v "$wrapper_variable" '%s' "$wrapper_path"
    if [[ "$command_name" == "claude" ]]; then
        _cmux_install_cli_command_shim "$command_name" "$wrapper_path"
    fi
    case "$existing_type" in
        alias|function)
            return 0
            ;;
    esac

    # Keep the bundled wrapper ahead of later PATH mutations. Install it
    # via eval so an existing alias cannot break parsing.
    unalias "$command_name" >/dev/null 2>&1 || true
    if [[ "$command_name" == "claude" ]]; then
        eval "$command_name() { _cmux_claude_wrapper_command \"\$@\"; }"
    else
        eval "$command_name() { \"\${$wrapper_variable}\" \"\$@\"; }"
    fi
}
_cmux_install_cli_wrapper claude _CMUX_CLAUDE_WRAPPER cmux-claude-wrapper
_cmux_install_cli_wrapper grok _CMUX_GROK_WRAPPER
_cmux_now() {
    printf '%s\n' "${EPOCHSECONDS:-$SECONDS}"
}

# Throttle heavy work to avoid prompt latency.
_CMUX_PWD_LAST_PWD="${_CMUX_PWD_LAST_PWD:-}"
_CMUX_GIT_LAST_PWD="${_CMUX_GIT_LAST_PWD:-}"
_CMUX_GIT_LAST_RUN="${_CMUX_GIT_LAST_RUN:-0}"
_CMUX_GIT_JOB_PID="${_CMUX_GIT_JOB_PID:-}"
_CMUX_GIT_JOB_STARTED_AT="${_CMUX_GIT_JOB_STARTED_AT:-0}"
_CMUX_GIT_HEAD_LAST_PWD="${_CMUX_GIT_HEAD_LAST_PWD:-}"
_CMUX_GIT_HEAD_PATH="${_CMUX_GIT_HEAD_PATH:-}"
_CMUX_GIT_HEAD_SIGNATURE="${_CMUX_GIT_HEAD_SIGNATURE:-}"
_CMUX_GIT_ACTIVE_PWD_FILE="${_CMUX_GIT_ACTIVE_PWD_FILE:-$(/usr/bin/mktemp "${TMPDIR:-/tmp}/cmux-git-active-pwd.XXXXXX" 2>/dev/null || true)}"
_CMUX_PR_POLL_PID="${_CMUX_PR_POLL_PID:-}"
_CMUX_PR_POLL_PWD="${_CMUX_PR_POLL_PWD:-}"
_CMUX_PR_LAST_BRANCH="${_CMUX_PR_LAST_BRANCH:-}"
_CMUX_PR_NO_PR_BRANCH="${_CMUX_PR_NO_PR_BRANCH:-}"
_CMUX_PR_POLL_INTERVAL="${_CMUX_PR_POLL_INTERVAL:-45}"
_CMUX_PR_FORCE="${_CMUX_PR_FORCE:-0}"
_CMUX_PR_DEBUG="${_CMUX_PR_DEBUG:-0}"
_CMUX_ASYNC_JOB_TIMEOUT="${_CMUX_ASYNC_JOB_TIMEOUT:-20}"
_CMUX_LAST_PR_ACTION="${_CMUX_LAST_PR_ACTION:-}"
_CMUX_LAST_PR_TARGET="${_CMUX_LAST_PR_TARGET:-}"
_CMUX_PR_ACTION_HINT_FILE="${_CMUX_PR_ACTION_HINT_FILE:-${TMPDIR:-/tmp}/cmux-pr-action-$$}"
_CMUX_BASH_HISTORY_LAST_FILE="${_CMUX_BASH_HISTORY_LAST_FILE:-${TMPDIR:-/tmp}/cmux-history-last-$$}"

_CMUX_PORTS_LAST_RUN="${_CMUX_PORTS_LAST_RUN:-0}"
_CMUX_SHELL_ACTIVITY_LAST="${_CMUX_SHELL_ACTIVITY_LAST:-}"
_CMUX_TTY_NAME="${_CMUX_TTY_NAME:-}"
_CMUX_TTY_REPORTED="${_CMUX_TTY_REPORTED:-0}"
_CMUX_TMUX_PUSH_SIGNATURE="${_CMUX_TMUX_PUSH_SIGNATURE:-}"
_CMUX_TMUX_PULL_SIGNATURE="${_CMUX_TMUX_PULL_SIGNATURE:-}"
_CMUX_TMUX_SYNC_KEYS=(
    CMUX_BUNDLED_CLI_PATH
    CMUX_BUNDLE_ID
    CMUXD_UNIX_PATH
    CMUXTERM_REPO_ROOT
    CMUX_DEBUG_LOG
    CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION
    CMUX_PORT
    CMUX_PORT_END
    CMUX_PORT_RANGE
    CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD
    CMUX_SHELL_INTEGRATION
    CMUX_SHELL_INTEGRATION_DIR
    CMUX_SOCKET_ENABLE
    CMUX_SOCKET_MODE
    CMUX_SOCKET_PATH
    CMUX_TAB_ID
    CMUX_TAG
    CMUX_WORKSPACE_ID
)
_CMUX_TMUX_SURFACE_SCOPED_KEYS=(
    CMUX_PANEL_ID
    CMUX_SURFACE_ID
)

_cmux_tmux_sync_key_is_managed() {
    local candidate="$1"
    local key
    for key in "${_CMUX_TMUX_SYNC_KEYS[@]}"; do
        [[ "$key" == "$candidate" ]] && return 0
    done
    return 1
}

_cmux_tmux_shell_env_signature() {
    local key value first=1
    for key in "${_CMUX_TMUX_SYNC_KEYS[@]}"; do
        value="${!key}"
        [[ -n "$value" ]] || continue
        if (( first )); then
            printf '%s=%s' "$key" "$value"
            first=0
        else
            printf '\037%s=%s' "$key" "$value"
        fi
    done
}

_cmux_tmux_publish_cmux_environment() {
    [[ -z "$TMUX" ]] || return 0
    command -v tmux >/dev/null 2>&1 || return 0

    local signature
    signature="$(_cmux_tmux_shell_env_signature)"
    [[ -n "$signature" ]] || return 0
    [[ "$signature" == "$_CMUX_TMUX_PUSH_SIGNATURE" ]] && return 0

    local key value
    for key in "${_CMUX_TMUX_SYNC_KEYS[@]}"; do
        value="${!key}"
        [[ -n "$value" ]] || continue
        tmux set-environment -g "$key" "$value" >/dev/null 2>&1 || return 0
    done

    for key in "${_CMUX_TMUX_SURFACE_SCOPED_KEYS[@]}"; do
        tmux set-environment -gu "$key" >/dev/null 2>&1 || return 0
    done

    _CMUX_TMUX_PUSH_SIGNATURE="$signature"
}

_cmux_tmux_refresh_cmux_environment() {
    [[ -n "$TMUX" ]] || return 0
    command -v tmux >/dev/null 2>&1 || return 0

    local output filtered line key value did_change=0
    for key in "${_CMUX_TMUX_SURFACE_SCOPED_KEYS[@]}"; do
        if [[ -n "${!key}" ]]; then
            unset "$key"
            did_change=1
        fi
    done

    output="$(tmux show-environment 2>/dev/null)" || return 0

    while IFS= read -r line; do
        [[ "$line" == CMUX_* ]] || continue
        key="${line%%=*}"
        _cmux_tmux_sync_key_is_managed "$key" || continue
        filtered+="${line}"$'\n'
    done <<< "$output"

    [[ -n "$filtered" ]] || return 0
    [[ "$filtered" == "$_CMUX_TMUX_PULL_SIGNATURE" ]] && (( ! did_change )) && return 0

    while IFS= read -r line; do
        [[ "$line" == CMUX_* ]] || continue
        key="${line%%=*}"
        _cmux_tmux_sync_key_is_managed "$key" || continue
        value="${line#*=}"
        if [[ "${!key}" != "$value" ]]; then
            printf -v "$key" '%s' "$value"
            export "$key"
            did_change=1
        fi
    done <<< "$filtered"

    _CMUX_TMUX_PULL_SIGNATURE="$filtered"
    if (( did_change )); then
        _CMUX_TTY_REPORTED=0
        _CMUX_SHELL_ACTIVITY_LAST=""
        _CMUX_PWD_LAST_PWD=""
        _CMUX_GIT_LAST_PWD=""
        _CMUX_GIT_HEAD_LAST_PWD=""
        _CMUX_GIT_HEAD_PATH=""
        _CMUX_GIT_HEAD_SIGNATURE=""
        _CMUX_PR_FORCE=1
        _cmux_stop_pr_poll_loop
    fi
}

_cmux_tmux_sync_cmux_environment() {
    if [[ -n "$TMUX" ]]; then
        _cmux_tmux_refresh_cmux_environment
    else
        _cmux_tmux_publish_cmux_environment
    fi
}

_cmux_git_resolve_head_path() {
    # Resolve the HEAD file path without invoking git (fast; works for worktrees).
    local dir="${1:-$PWD}"
    while :; do
        if [[ -d "$dir/.git" ]]; then
            printf '%s\n' "$dir/.git/HEAD"
            return 0
        fi
        if [[ -f "$dir/.git" ]]; then
            local line gitdir
            IFS= read -r line < "$dir/.git" || line=""
            if [[ "$line" == gitdir:* ]]; then
                gitdir="${line#gitdir:}"
                gitdir="${gitdir## }"
                gitdir="${gitdir%% }"
                [[ -n "$gitdir" ]] || return 1
                [[ "$gitdir" != /* ]] && gitdir="$dir/$gitdir"
                printf '%s\n' "$gitdir/HEAD"
                return 0
            fi
        fi
        [[ "$dir" == "/" || -z "$dir" ]] && break
        dir="$(dirname "$dir")"
    done
    return 1
}

_cmux_git_resolve_git_dir() {
    local repo_path="${1:-$PWD}"
    local head_path
    head_path="$(_cmux_git_resolve_head_path "$repo_path" 2>/dev/null || true)"
    [[ -n "$head_path" ]] || return 1
    dirname "$head_path"
}

_cmux_git_head_signature() {
    local head_path="$1"
    [[ -n "$head_path" && -r "$head_path" ]] || return 1
    local line
    IFS= read -r line < "$head_path" || return 1
    printf '%s\n' "$line"
}

_cmux_git_branch_for_path() {
    local repo_path="$1"
    local head_path="" head_line="" prefix="ref: refs/heads/"
    head_path="$(_cmux_git_resolve_head_path "$repo_path" 2>/dev/null || true)"
    [[ -n "$head_path" && -r "$head_path" ]] || return 1
    IFS= read -r head_line < "$head_path" || return 1
    [[ "$head_line" == "$prefix"* ]] || return 1
    printf '%s\n' "${head_line#$prefix}"
}

_cmux_set_git_active_pwd() {
    local active_pwd="$1"
    [[ -n "$active_pwd" ]] || return 0
    [[ -n "${_CMUX_GIT_ACTIVE_PWD_FILE:-}" ]] || return 0
    printf '%s\n' "$active_pwd" >| "$_CMUX_GIT_ACTIVE_PWD_FILE" 2>/dev/null || true
}

_cmux_git_report_path_is_active() {
    local repo_path="$1"
    [[ -n "$repo_path" ]] || return 1
    [[ -n "${_CMUX_GIT_ACTIVE_PWD_FILE:-}" ]] || return 0
    [[ -r "$_CMUX_GIT_ACTIVE_PWD_FILE" ]] || return 0

    local active_pwd=""
    IFS= read -r active_pwd < "$_CMUX_GIT_ACTIVE_PWD_FILE" || active_pwd=""
    # No recorded cwd yet, or the report targets the current cwd exactly: allow.
    [[ -z "$active_pwd" || "$repo_path" == "$active_pwd" ]] && return 0

    # Otherwise the report is valid only when the current cwd is in the SAME
    # repository as repo_path. This keeps live branch updates flowing after an
    # in-repo `cd pkg` while still dropping a report once the shell has left the
    # repo entirely (the stale-branch case). Resolve both HEAD paths without
    # invoking git and compare.
    local repo_head active_head
    repo_head="$(_cmux_git_resolve_head_path "$repo_path" 2>/dev/null || true)"
    active_head="$(_cmux_git_resolve_head_path "$active_pwd" 2>/dev/null || true)"
    [[ -n "$repo_head" && "$repo_head" == "$active_head" ]]
}

_cmux_report_git_branch_for_path() {
    local repo_path="$1"
    [[ "${CMUX_NO_GIT_WATCH:-}" == "1" ]] && return 0
    [[ -n "$repo_path" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    if _cmux_socket_is_unix; then
        [[ -n "$CMUX_PANEL_ID" ]] || return 0
    fi
    _cmux_git_report_path_is_active "$repo_path" || return 0
    local branch dirty_opt="--status=unknown"
    branch="$(_cmux_git_branch_for_path "$repo_path" 2>/dev/null || true)"
    _cmux_git_report_path_is_active "$repo_path" || return 0
    if [[ -n "$branch" ]]; then
        if _cmux_socket_is_unix; then
            _cmux_send "report_git_branch $branch $dirty_opt --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
        else
            _cmux_report_git_branch_via_relay "$branch" || true
        fi
    else
        if _cmux_socket_is_unix; then
            _cmux_send "clear_git_branch --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
        else
            _cmux_clear_git_branch_via_relay || true
        fi
    fi
}

_cmux_report_tty_payload() {
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$_CMUX_TTY_NAME" ]] || return 0

    local payload="report_tty $_CMUX_TTY_NAME --tab=$CMUX_TAB_ID"
    if [[ -z "$TMUX" ]]; then
        [[ -n "$CMUX_PANEL_ID" ]] || return 0
        payload+=" --panel=$CMUX_PANEL_ID"
    fi

    printf '%s\n' "$payload"
}

_cmux_report_tty_once() {
    # Send the TTY name to the app once per session so the batched port scanner
    # knows which TTY belongs to this panel.
    (( _CMUX_TTY_REPORTED )) && return 0
    _cmux_has_port_scan_transport || return 0

    if _cmux_socket_is_unix; then
        local payload=""
        payload="$(_cmux_report_tty_payload)"
        [[ -n "$payload" ]] || return 0
        _CMUX_TTY_REPORTED=1
        _cmux_send_bg "$payload"
    else
        [[ -n "$_CMUX_TTY_NAME" ]] || return 0
        # Keep the first relay TTY report synchronous so the server can resolve
        # the target surface before command-start kicks begin their scan burst.
        _cmux_report_tty_via_relay || return 0
        _CMUX_TTY_REPORTED=1
    fi
}

_cmux_report_shell_activity_state() {
    local state="$1"
    [[ -n "$state" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    if _cmux_socket_is_unix; then
        [[ -n "$CMUX_PANEL_ID" ]] || return 0
    fi
    [[ "$_CMUX_SHELL_ACTIVITY_LAST" == "$state" ]] && return 0
    _CMUX_SHELL_ACTIVITY_LAST="$state"
    if _cmux_socket_is_unix; then
        _cmux_send_bg "report_shell_state $state --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
    else
        _cmux_report_shell_activity_state_via_relay "$state" || _CMUX_SHELL_ACTIVITY_LAST=""
    fi
}

_cmux_reset_terminal_keyboard_protocols() {
    [[ -t 1 || -n "${CMUX_TEST_FORCE_KEYBOARD_RESET:-}${CMUX_TEST_FORCE_KITTY_RESET:-}" ]] || return 0
    # A crashed TUI may leave keyboard protocol state pushed. At a fresh shell
    # prompt, return terminal input encoding to plain readline bytes.
    printf '\033[>m\033[<8u'
}

_cmux_ports_kick() {
    local reason="${1:-command}"
    # Lightweight: just tell the app to run a batched scan for this panel.
    # The app coalesces kicks across all panels and runs a single ps+lsof.
    _cmux_has_port_scan_transport || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    if _cmux_socket_is_unix; then
        [[ -n "$CMUX_PANEL_ID" ]] || return 0
    fi
    _CMUX_PORTS_LAST_RUN="$(_cmux_now)"
    if _cmux_socket_is_unix; then
        _cmux_send_bg "ports_kick --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID --reason=$reason"
    else
        _cmux_ports_kick_via_relay "$reason"
    fi
}

_cmux_clear_pr_for_panel() {
    [[ "${CMUX_NO_GIT_WATCH:-}" == "1" ]] && return 0
    [[ -S "$CMUX_SOCKET_PATH" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$CMUX_PANEL_ID" ]] || return 0
    # Synchronous: must arrive before the next report_pr from the poll loop.
    _cmux_send "clear_pr --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
}

_cmux_clear_pr_command_hint_file() {
    [[ -n "${_CMUX_PR_ACTION_HINT_FILE:-}" ]] || return 0
    /bin/rm -f -- "$_CMUX_PR_ACTION_HINT_FILE" >/dev/null 2>&1 || true
}

_cmux_store_pr_command_hint() {
    [[ -n "${_CMUX_PR_ACTION_HINT_FILE:-}" ]] || return 0
    if [[ -z "$_CMUX_LAST_PR_ACTION" ]]; then
        _cmux_clear_pr_command_hint_file
        return 0
    fi

    local target="$_CMUX_LAST_PR_TARGET"
    target="${target//$'\n'/ }"
    target="${target//$'\r'/ }"
    target="${target//$'\t'/ }"
    printf '%s\t%s\n' "$_CMUX_LAST_PR_ACTION" "$target" > "$_CMUX_PR_ACTION_HINT_FILE" 2>/dev/null || true
}

_cmux_load_pr_command_hint() {
    [[ -n "${_CMUX_PR_ACTION_HINT_FILE:-}" && -r "$_CMUX_PR_ACTION_HINT_FILE" ]] || return 0

    local action="" target=""
    IFS=$'\t' read -r action target < "$_CMUX_PR_ACTION_HINT_FILE" || true
    _cmux_clear_pr_command_hint_file

    case "$action" in
        merge|close|reopen|create|checkout|ready|edit|view)
            _CMUX_LAST_PR_ACTION="$action"
            _CMUX_LAST_PR_TARGET="$target"
            ;;
    esac
}

_cmux_record_pr_command_hint() {
    local cmd="$1"
    _CMUX_LAST_PR_ACTION=""
    _CMUX_LAST_PR_TARGET=""
    _cmux_clear_pr_command_hint_file

    local -a words=()
    read -r -a words <<< "$cmd"

    local index=0
    local word base
    while (( index < ${#words[@]} )); do
        word="${words[index]}"

        case "$word" in
            *=*)
                index=$(( index + 1 ))
                continue ;;
            exec|command|builtin|noglob|time)
                index=$(( index + 1 ))
                continue ;;
            env)
                index=$(( index + 1 ))
                while (( index < ${#words[@]} )); do
                    word="${words[index]}"
                    case "$word" in
                        -*|*=*)
                            index=$(( index + 1 ))
                            continue ;;
                    esac
                    break
                done
                continue ;;
        esac

        base="${word##*/}"
        [[ "$base" == "gh" ]] || return 0
        index=$(( index + 1 ))
        break
    done

    (( index + 1 < ${#words[@]} )) || return 0
    [[ "${words[index]}" == "pr" ]] || return 0
    local action="${words[index + 1]}"
    action="$(printf '%s' "$action" | tr '[:upper:]' '[:lower:]')"
    case "$action" in
        merge|close|reopen|create|checkout|ready|edit|view)
            _CMUX_LAST_PR_ACTION="$action" ;;
        *)
            return 0 ;;
    esac

    index=$(( index + 2 ))
    while (( index < ${#words[@]} )); do
        word="${words[index]}"
        case "$word" in
            --*=*)
                index=$(( index + 1 ))
                continue ;;
            --*)
                index=$(( index + 2 ))
                continue ;;
            -*)
                index=$(( index + 1 ))
                continue ;;
            *)
                _CMUX_LAST_PR_TARGET="$word"
                break ;;
        esac
    done

    _cmux_store_pr_command_hint
}

_cmux_emit_pr_command_hint() {
    [[ "${CMUX_NO_PR_WATCH:-}" == "1" ]] && return 0
    [[ -S "$CMUX_SOCKET_PATH" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$CMUX_PANEL_ID" ]] || return 0
    if [[ -z "$_CMUX_LAST_PR_ACTION" ]]; then
        _cmux_load_pr_command_hint
    fi
    [[ -n "$_CMUX_LAST_PR_ACTION" ]] || return 0

    local payload="report_pr_action $_CMUX_LAST_PR_ACTION --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
    if [[ -n "$_CMUX_LAST_PR_TARGET" ]]; then
        local quoted_target="${_CMUX_LAST_PR_TARGET//\"/\\\"}"
        payload+=" --target=\"$quoted_target\""
    fi
    _cmux_send_bg "$payload"
    _CMUX_LAST_PR_ACTION=""
    _CMUX_LAST_PR_TARGET=""
    _cmux_clear_pr_command_hint_file
}

_cmux_pr_output_indicates_no_pull_request() {
    local output="$1"
    output="$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')"
    [[ "$output" == *"no pull requests found"* \
        || "$output" == *"no pull request found"* \
        || "$output" == *"no pull requests associated"* \
        || "$output" == *"no pull request associated"* ]]
}

_cmux_git_config_resolve_include_path() {
    local path="$1" config_dir="$2"
    case "$path" in
        "~")
            printf '%s\n' "$HOME" ;;
        "~/"*)
            printf '%s/%s\n' "$HOME" "${path#~/}" ;;
        /*)
            printf '%s\n' "$path" ;;
        *)
            printf '%s/%s\n' "$config_dir" "$path" ;;
    esac
}

_cmux_git_config_gitdir_pattern_matches() {
    local pattern="$1" repo_path="$2" git_dir="$3" common_dir="$4" case_insensitive="$5"
    local expanded="$pattern" candidate cmp_candidate cmp_pattern prefix

    case "$expanded" in
        "~")
            expanded="$HOME" ;;
        "~/"*)
            expanded="$HOME/${expanded#~/}" ;;
    esac
    if [[ "$expanded" == */ ]]; then
        prefix="$expanded"
        [[ "$case_insensitive" == "1" ]] && prefix="$(printf '%s' "$prefix" | tr '[:upper:]' '[:lower:]')"
        for candidate in "$git_dir" "$common_dir" "$repo_path"; do
            cmp_candidate="$candidate"
            [[ "$case_insensitive" == "1" ]] && cmp_candidate="$(printf '%s' "$cmp_candidate" | tr '[:upper:]' '[:lower:]')"
            [[ "$cmp_candidate" == "${prefix%/}" || "$cmp_candidate/" == "$prefix"* ]] && return 0
        done
        return 1
    fi
    if [[ "$expanded" == */'**' ]]; then
        prefix="${expanded%/\*\*}/"
        [[ "$case_insensitive" == "1" ]] && prefix="$(printf '%s' "$prefix" | tr '[:upper:]' '[:lower:]')"
        for candidate in "$git_dir" "$common_dir" "$repo_path"; do
            cmp_candidate="$candidate"
            [[ "$case_insensitive" == "1" ]] && cmp_candidate="$(printf '%s' "$cmp_candidate" | tr '[:upper:]' '[:lower:]')"
            [[ "$cmp_candidate" == "${prefix%/}" || "$cmp_candidate/" == "$prefix"* ]] && return 0
        done
        return 1
    fi

    cmp_pattern="$expanded"
    [[ "$case_insensitive" == "1" ]] && cmp_pattern="$(printf '%s' "$cmp_pattern" | tr '[:upper:]' '[:lower:]')"
    for candidate in "$git_dir" "$common_dir" "$repo_path"; do
        cmp_candidate="$candidate"
        [[ "$case_insensitive" == "1" ]] && cmp_candidate="$(printf '%s' "$cmp_candidate" | tr '[:upper:]' '[:lower:]')"
        [[ "$cmp_candidate" == $cmp_pattern || "$cmp_candidate/" == $cmp_pattern ]] && return 0
    done
    return 1
}

_cmux_git_config_include_condition_matches() {
    local condition="$1" repo_path="$2" git_dir="$3" common_dir="$4"
    local lower pattern
    lower="$(printf '%s' "$condition" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
        gitdir/i:*)
            pattern="${condition#gitdir/i:}"
            _cmux_git_config_gitdir_pattern_matches "$pattern" "$repo_path" "$git_dir" "$common_dir" 1 ;;
        gitdir:*)
            pattern="${condition#gitdir:}"
            _cmux_git_config_gitdir_pattern_matches "$pattern" "$repo_path" "$git_dir" "$common_dir" 0 ;;
        *)
            return 1 ;;
    esac
}

_cmux_git_origin_url_read_config_file() {
    local repo_path="$1" git_dir="$2" common_dir="$3" config_file="$4"
    local config_dir="" output=""
    local kind="" entry_payload="" entry_value="" include_path=""

    [[ -r "$config_file" ]] || return 0
    case "$_cmux_git_origin_url_seen" in
        *$'\n'"$config_file"$'\n'*) return 0 ;;
    esac
    _cmux_git_origin_url_depth=$(( _cmux_git_origin_url_depth + 1 ))
    [[ "$_cmux_git_origin_url_depth" -le 32 ]] || return 0
    _cmux_git_origin_url_seen+="$config_file"$'\n'

    config_dir="$(dirname "$config_file")"
    output="$(awk '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        function strip_inline_comment(s, i, c, out, previous_was_space, in_quote, escaped) {
            out = ""
            previous_was_space = 1
            in_quote = 0
            escaped = 0
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (escaped) {
                    out = out c
                    escaped = 0
                    previous_was_space = (c ~ /[[:space:]]/)
                    continue
                }
                if (in_quote && c == "\\") {
                    out = out c
                    escaped = 1
                    previous_was_space = 0
                    continue
                }
                if (c == "\"") {
                    out = out c
                    in_quote = !in_quote
                    previous_was_space = 0
                    continue
                }
                if (!in_quote && previous_was_space && (c == "#" || c == ";")) {
                    break
                }
                out = out c
                previous_was_space = (c ~ /[[:space:]]/)
            }
            return out
        }
        function unquote_config_value(s, i, c, out, escaped) {
            s = trim(s)
            if (length(s) >= 2 && substr(s, 1, 1) == "\"" && substr(s, length(s), 1) == "\"") {
                out = ""
                escaped = 0
                for (i = 2; i < length(s); i++) {
                    c = substr(s, i, 1)
                    if (escaped) {
                        out = out c
                        escaped = 0
                        continue
                    }
                    if (c == "\\") {
                        escaped = 1
                        continue
                    }
                    out = out c
                }
                if (escaped) {
                    out = out "\\"
                }
                return out
            }
            return s
        }
        function path_value(line) {
            sub(/^[^=]*=/, "", line)
            return unquote_config_value(line)
        }
        {
            line = strip_inline_comment($0)
            trimmed = trim(line)
            if (trimmed ~ /^\[remote[[:space:]]+"origin"\][[:space:]]*$/) {
                section = "remote"
                condition = ""
                next
            }
            if (trimmed == "[include]") {
                section = "include"
                condition = ""
                next
            }
            if (trimmed ~ /^\[includeIf[[:space:]]+"/) {
                section = "includeIf"
                condition = trimmed
                sub(/^\[includeIf[[:space:]]+"/, "", condition)
                sub(/"\][[:space:]]*$/, "", condition)
                next
            }
            if (trimmed ~ /^\[/) {
                section = ""
                condition = ""
                next
            }
            if (section == "remote" && line ~ /^[[:space:]]*url[[:space:]]*=/) {
                print "remote\t" path_value(line) "\t"
            }
            if (section == "include" && line ~ /^[[:space:]]*path[[:space:]]*=/) {
                print "include\t" path_value(line) "\t"
            }
            if (section == "includeIf" && line ~ /^[[:space:]]*path[[:space:]]*=/) {
                print "includeIf\t" condition "\t" path_value(line)
            }
        }
    ' "$config_file" 2>/dev/null)"

    while IFS=$'\t' read -r kind entry_payload entry_value; do
        case "$kind" in
            remote)
                [[ -n "$entry_payload" ]] && _cmux_git_origin_url_result="$entry_payload" ;;
            include)
                include_path="$(_cmux_git_config_resolve_include_path "$entry_payload" "$config_dir")"
                [[ -r "$include_path" ]] && _cmux_git_origin_url_read_config_file "$repo_path" "$git_dir" "$common_dir" "$include_path" ;;
            includeIf)
                if _cmux_git_config_include_condition_matches "$entry_payload" "$repo_path" "$git_dir" "$common_dir"; then
                    include_path="$(_cmux_git_config_resolve_include_path "$entry_value" "$config_dir")"
                    [[ -r "$include_path" ]] && _cmux_git_origin_url_read_config_file "$repo_path" "$git_dir" "$common_dir" "$include_path"
                fi ;;
        esac
    done <<< "$output"
}

_cmux_git_origin_url_from_config_files() {
    local repo_path="$1" git_dir="$2" common_dir="$3"
    local _cmux_git_origin_url_seen=$'\n'
    local _cmux_git_origin_url_depth=0
    local _cmux_git_origin_url_result=""

    [[ -r "$common_dir/config" ]] && _cmux_git_origin_url_read_config_file "$repo_path" "$git_dir" "$common_dir" "$common_dir/config"
    [[ "$git_dir" != "$common_dir" && -r "$git_dir/config" ]] && _cmux_git_origin_url_read_config_file "$repo_path" "$git_dir" "$common_dir" "$git_dir/config"
    [[ -n "$_cmux_git_origin_url_result" ]] && printf '%s\n' "$_cmux_git_origin_url_result"
}

_cmux_github_repo_slug_for_path() {
    local repo_path="$1"
    local git_dir="" common_dir="" remote_url="" path_part=""
    [[ -n "$repo_path" ]] || return 0

    git_dir="$(_cmux_git_resolve_git_dir "$repo_path" 2>/dev/null || true)"
    [[ -n "$git_dir" ]] || return 0
    common_dir="$git_dir"
    if [[ -r "$git_dir/commondir" ]]; then
        IFS= read -r common_dir < "$git_dir/commondir" || common_dir=""
        common_dir="${common_dir## }"
        common_dir="${common_dir%% }"
        [[ "$common_dir" != /* ]] && common_dir="$git_dir/$common_dir"
    fi
    remote_url="$(_cmux_git_origin_url_from_config_files "$repo_path" "$git_dir" "$common_dir")"
    [[ -n "$remote_url" ]] || return 0

    case "$remote_url" in
        git@github.com:*)
            path_part="${remote_url#git@github.com:}"
            ;;
        ssh://git@github.com/*)
            path_part="${remote_url#ssh://git@github.com/}"
            ;;
        https://github.com/*)
            path_part="${remote_url#https://github.com/}"
            ;;
        http://github.com/*)
            path_part="${remote_url#http://github.com/}"
            ;;
        git://github.com/*)
            path_part="${remote_url#git://github.com/}"
            ;;
        *)
            return 0
            ;;
    esac

    path_part="${path_part%.git}"
    [[ "$path_part" == */* ]] || return 0
    printf '%s\n' "$path_part"
}

_cmux_pr_cache_prefix() {
    [[ -n "$CMUX_PANEL_ID" ]] || return 1
    printf '%s\n' "/tmp/cmux-pr-cache-${CMUX_PANEL_ID}"
}

_cmux_pr_force_signal_path() {
    [[ -n "$CMUX_PANEL_ID" ]] || return 1
    printf '%s\n' "/tmp/cmux-pr-force-${CMUX_PANEL_ID}"
}

_cmux_pr_debug_log() {
    (( _CMUX_PR_DEBUG )) || return 0

    local branch="$1"
    local event="$2"
    local now
    now="$(_cmux_now)"
    printf '%s\tbranch=%s\tevent=%s\n' "$now" "$branch" "$event" >> /tmp/cmux-pr-debug.log
}

_cmux_pr_cache_clear() {
    local prefix=""
    prefix="$(_cmux_pr_cache_prefix 2>/dev/null || true)"
    if [[ -n "$prefix" ]]; then
        /bin/rm -f -- \
            "${prefix}.branch" \
            "${prefix}.repo" \
            "${prefix}.result" \
            "${prefix}.timestamp" \
            "${prefix}.no-pr-branch" \
            >/dev/null 2>&1 || true
    fi

    _CMUX_PR_LAST_BRANCH=""
    _CMUX_PR_NO_PR_BRANCH=""
}

_cmux_pr_request_probe() {
    local signal_path=""
    signal_path="$(_cmux_pr_force_signal_path 2>/dev/null || true)"
    [[ -n "$signal_path" ]] || return 0
    : >| "$signal_path"
}

_cmux_report_pr_for_path() {
    local repo_path="$1"
    local force_probe="${2:-0}"
    if [[ "${CMUX_NO_PR_WATCH:-}" == "1" ]]; then
        _cmux_pr_cache_clear
        _cmux_clear_pr_for_panel
        return 0
    fi
    [[ -n "$repo_path" ]] || {
        _cmux_pr_cache_clear
        _cmux_clear_pr_for_panel
        return 0
    }
    [[ -d "$repo_path" ]] || {
        _cmux_pr_cache_clear
        _cmux_clear_pr_for_panel
        return 0
    }
    [[ -S "$CMUX_SOCKET_PATH" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$CMUX_PANEL_ID" ]] || return 0

    local branch repo_slug="" gh_output="" gh_error="" err_file="" gh_status number state url status_opt=""
    local now prefix="" branch_file="" repo_file="" result_file="" timestamp_file="" no_pr_branch_file=""
    local cache_branch="" cache_result="" cache_no_pr_branch=""
    local -a gh_repo_args=()
    now="$(_cmux_now)"
    branch="$(_cmux_git_branch_for_path "$repo_path" 2>/dev/null || true)"
    if [[ -z "$branch" ]] || ! command -v gh >/dev/null 2>&1; then
        _cmux_pr_debug_log "$branch" "cache-miss:clear"
        _cmux_pr_cache_clear
        _cmux_clear_pr_for_panel
        return 0
    fi

    prefix="$(_cmux_pr_cache_prefix 2>/dev/null || true)"
    if [[ -n "$prefix" ]]; then
        branch_file="${prefix}.branch"
        repo_file="${prefix}.repo"
        result_file="${prefix}.result"
        timestamp_file="${prefix}.timestamp"
        no_pr_branch_file="${prefix}.no-pr-branch"
        [[ -r "$branch_file" ]] && cache_branch="$(<"$branch_file")"
        [[ -r "$result_file" ]] && cache_result="$(<"$result_file")"
        [[ -r "$no_pr_branch_file" ]] && cache_no_pr_branch="$(<"$no_pr_branch_file")"
    fi

    _CMUX_PR_LAST_BRANCH="$cache_branch"
    _CMUX_PR_NO_PR_BRANCH="$cache_no_pr_branch"
    if [[ "$cache_branch" == "$branch" && -n "$cache_result" ]]; then
        _cmux_pr_debug_log "$branch" "cache-refresh"
    else
        _cmux_pr_debug_log "$branch" "cache-miss"
    fi

    repo_slug="$(_cmux_github_repo_slug_for_path "$repo_path")"
    if [[ -n "$repo_slug" ]]; then
        gh_repo_args=(--repo "$repo_slug")
    fi

    err_file="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/cmux-gh-pr-view.XXXXXX" 2>/dev/null || true)"
    [[ -n "$err_file" ]] || return 1
    gh_output="$(
        builtin cd "$repo_path" 2>/dev/null \
            && gh pr view "$branch" \
                "${gh_repo_args[@]}" \
                --json number,state,url \
                --jq '[.number, .state, .url] | @tsv' \
                2>"$err_file"
    )"
    gh_status=$?
    if [[ -f "$err_file" ]]; then
        gh_error="$("/bin/cat" -- "$err_file" 2>/dev/null || true)"
        /bin/rm -f -- "$err_file" >/dev/null 2>&1 || true
    fi

    if (( gh_status != 0 )) || [[ -z "$gh_output" ]]; then
        if (( gh_status == 0 )) && [[ -z "$gh_output" ]]; then
            if [[ -n "$prefix" ]]; then
                printf '%s\n' "$branch" >| "$branch_file"
                printf '%s\n' "$repo_path" >| "$repo_file"
                printf '%s\n' "$now" >| "$timestamp_file"
                printf '%s\n' "none" >| "$result_file"
                printf '%s\n' "$branch" >| "$no_pr_branch_file"
            fi
            _CMUX_PR_LAST_BRANCH="$branch"
            _CMUX_PR_NO_PR_BRANCH="$branch"
            _cmux_clear_pr_for_panel
            return 0
        fi
        if _cmux_pr_output_indicates_no_pull_request "$gh_error"; then
            if [[ -n "$prefix" ]]; then
                printf '%s\n' "$branch" >| "$branch_file"
                printf '%s\n' "$repo_path" >| "$repo_file"
                printf '%s\n' "$now" >| "$timestamp_file"
                printf '%s\n' "none" >| "$result_file"
                printf '%s\n' "$branch" >| "$no_pr_branch_file"
            fi
            _CMUX_PR_LAST_BRANCH="$branch"
            _CMUX_PR_NO_PR_BRANCH="$branch"
            _cmux_clear_pr_for_panel
            return 0
        fi

        # Always scope PR detection to the exact current branch. Preserve the
        # last-known PR badge when gh fails transiently, then retry on the next
        # background poll instead of showing a mismatched PR.
        return 1
    fi

    IFS=$'\t' read -r number state url <<< "$gh_output"
    if [[ -z "$number" || -z "$url" ]]; then
        return 1
    fi

    case "$state" in
        MERGED) status_opt="--state=merged" ;;
        OPEN) status_opt="--state=open" ;;
        CLOSED) status_opt="--state=closed" ;;
        *) return 1 ;;
    esac

    if [[ -n "$prefix" ]]; then
        printf '%s\n' "$branch" >| "$branch_file"
        printf '%s\n' "$repo_path" >| "$repo_file"
        printf '%s\n' "$now" >| "$timestamp_file"
        printf '%s\t%s\t%s\t%s\n' "pr" "$number" "$state" "$url" >| "$result_file"
        /bin/rm -f -- "$no_pr_branch_file" >/dev/null 2>&1 || true
    fi
    _CMUX_PR_LAST_BRANCH="$branch"
    _CMUX_PR_NO_PR_BRANCH=""

    local quoted_branch="${branch//\"/\\\"}"
    _cmux_send "report_pr $number $url $status_opt --branch=\"$quoted_branch\" --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
}

_cmux_child_pids() {
    local parent_pid="$1"
    [[ -n "$parent_pid" ]] || return 0
    /bin/ps -ax -o pid= -o ppid= 2>/dev/null | /usr/bin/awk -v parent="$parent_pid" '$2 == parent { print $1 }'
}

_cmux_kill_process_tree() {
    local pid="$1"
    local signal="${2:-TERM}"
    local child_pid=""
    [[ -n "$pid" ]] || return 0

    while IFS= read -r child_pid; do
        [[ -n "$child_pid" ]] || continue
        [[ "$child_pid" == "$pid" ]] && continue
        _cmux_kill_process_tree "$child_pid" "$signal"
    done < <(_cmux_child_pids "$pid")

    kill "-$signal" "$pid" >/dev/null 2>&1 || true
}

_cmux_run_pr_probe_with_timeout() {
    local repo_path="$1"
    local force_probe="${2:-0}"
    local probe_pid=""
    local started_at=""
    local now=""
    started_at="$(_cmux_now)"
    now=$started_at

    (
        _cmux_report_pr_for_path "$repo_path" "$force_probe"
    ) &
    probe_pid=$!

    while kill -0 "$probe_pid" >/dev/null 2>&1; do
        sleep 1
        now="$(_cmux_now)"
        if (( _CMUX_ASYNC_JOB_TIMEOUT > 0 )) && (( now - started_at >= _CMUX_ASYNC_JOB_TIMEOUT )); then
            _cmux_kill_process_tree "$probe_pid" TERM
            sleep 0.2
            if kill -0 "$probe_pid" >/dev/null 2>&1; then
                _cmux_kill_process_tree "$probe_pid" KILL
                sleep 0.2
            fi
            if ! kill -0 "$probe_pid" >/dev/null 2>&1; then
                wait "$probe_pid" >/dev/null 2>&1 || true
            fi
            return 1
        fi
    done

    wait "$probe_pid"
}

_cmux_halt_pr_poll_loop() {
    if [[ -n "$_CMUX_PR_POLL_PID" ]]; then
        # Process-group kill: background jobs are process-group leaders, so
        # negative PID kills the loop + all descendants (gh, sleep) without
        # the synchronous /bin/ps + awk of tree-kill (~5-13ms).
        kill -KILL -- -"$_CMUX_PR_POLL_PID" 2>/dev/null || true
    fi
    local signal_path=""
    signal_path="$(_cmux_pr_force_signal_path 2>/dev/null || true)"
    [[ -n "$signal_path" ]] && /bin/rm -f -- "$signal_path" >/dev/null 2>&1 || true
    _CMUX_PR_POLL_PID=""
    _CMUX_PR_POLL_PWD=""
}

_cmux_stop_pr_poll_loop() {
    _cmux_halt_pr_poll_loop
    _cmux_pr_cache_clear
}

_cmux_start_pr_poll_loop() {
    if [[ "${CMUX_NO_PR_WATCH:-}" == "1" ]]; then
        _cmux_stop_pr_poll_loop
        return 0
    fi
    [[ "${CMUX_NO_GIT_WATCH:-}" == "1" ]] && return 0
    [[ -S "$CMUX_SOCKET_PATH" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$CMUX_PANEL_ID" ]] || return 0

    local watch_pwd="${1:-$PWD}"
    local force_restart="${2:-0}"
    local watch_shell_pid="$$"
    local interval="${_CMUX_PR_POLL_INTERVAL:-45}"

    if [[ "$force_restart" != "1" && "$watch_pwd" == "$_CMUX_PR_POLL_PWD" && -n "$_CMUX_PR_POLL_PID" ]] \
        && kill -0 "$_CMUX_PR_POLL_PID" 2>/dev/null; then
        return 0
    fi

    if [[ -n "$_CMUX_PR_POLL_PID" ]] && kill -0 "$_CMUX_PR_POLL_PID" 2>/dev/null; then
        _cmux_halt_pr_poll_loop
    else
        _CMUX_PR_POLL_PID=""
    fi
    _CMUX_PR_POLL_PWD="$watch_pwd"

    {
        local signal_path=""
        signal_path="$(_cmux_pr_force_signal_path 2>/dev/null || true)"
        while :; do
            kill -0 "$watch_shell_pid" 2>/dev/null || break
            local force_probe=0
            if [[ -n "$signal_path" && -f "$signal_path" ]]; then
                force_probe=1
                /bin/rm -f -- "$signal_path" >/dev/null 2>&1 || true
            fi
            _cmux_run_pr_probe_with_timeout "$watch_pwd" "$force_probe" || true

            local slept=0
            while (( slept < interval )); do
                kill -0 "$watch_shell_pid" 2>/dev/null || exit 0
                if [[ -n "$signal_path" && -f "$signal_path" ]]; then
                    break
                fi
                sleep 1
                slept=$(( slept + 1 ))
            done
        done
    } >/dev/null 2>&1 &
    _CMUX_PR_POLL_PID=$!
    disown "$_CMUX_PR_POLL_PID" 2>/dev/null || disown
}

_cmux_bash_cleanup() {
    _cmux_stop_pr_poll_loop
    [[ -n "${_CMUX_GIT_ACTIVE_PWD_FILE:-}" ]] && /bin/rm -f -- "$_CMUX_GIT_ACTIVE_PWD_FILE" >/dev/null 2>&1 || true
}

_cmux_command_starts_nested_shell() {
    local cmd="$1"
    local -a words=()
    read -r -a words <<< "$cmd"

    local index=0
    local word base
    while (( index < ${#words[@]} )); do
        word="${words[index]}"

        case "$word" in
            *=*)
                index=$(( index + 1 ))
                continue ;;
            exec|command|builtin|noglob|time)
                index=$(( index + 1 ))
                continue ;;
            env)
                index=$(( index + 1 ))
                while (( index < ${#words[@]} )); do
                    word="${words[index]}"
                    case "$word" in
                        -*|*=*)
                            index=$(( index + 1 ))
                            continue ;;
                    esac
                    break
                done
                continue ;;
        esac

        base="${word##*/}"
        case "$base" in
            bash|zsh|sh|fish|nu|nix-shell)
                return 0 ;;
            nix)
                local next_index=$(( index + 1 ))
                local next_word="${words[next_index]:-}"
                case "$next_word" in
                    develop|shell)
                        return 0 ;;
                esac ;;
        esac

        return 1
    done

    return 1
}

_cmux_preexec_command() {
    local cmd="${1:-${BASH_COMMAND:-}}"
    _cmux_tmux_sync_cmux_environment

    local cmux_has_unix_socket=0
    _cmux_socket_is_unix && cmux_has_unix_socket=1
    (( cmux_has_unix_socket )) || _cmux_has_port_scan_transport || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    _cmux_record_pr_command_hint "$cmd"

    if [[ -z "$_CMUX_TTY_NAME" ]]; then
        local t
        t="$(tty 2>/dev/null || true)"
        t="${t##*/}"
        [[ -n "$t" && "$t" != "not a tty" ]] && _CMUX_TTY_NAME="$t"
    fi

    _cmux_report_shell_activity_state running
    _cmux_report_tty_once
    _cmux_ports_kick command
    _cmux_halt_pr_poll_loop
    if _cmux_command_starts_nested_shell "$cmd"; then
        return 0
    fi
}

_cmux_bash_history_command() {
    local HISTTIMEFORMAT=
    local history_file="${TMPDIR:-/tmp}/cmux-history-$$-${RANDOM:-0}"
    local line="" history_number="" last_number=""
    builtin history 1 > "$history_file" 2>/dev/null || {
        /bin/rm -f -- "$history_file" >/dev/null 2>&1 || true
        return 1
    }
    IFS= read -r line < "$history_file" || line=""
    /bin/rm -f -- "$history_file" >/dev/null 2>&1 || true
    if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+(.*)$ ]]; then
        history_number="${BASH_REMATCH[1]}"
        if [[ -n "${_CMUX_BASH_HISTORY_LAST_FILE:-}" && -r "$_CMUX_BASH_HISTORY_LAST_FILE" ]]; then
            IFS= read -r last_number < "$_CMUX_BASH_HISTORY_LAST_FILE" || last_number=""
        fi
        [[ "$history_number" == "$last_number" ]] && return 1
        if [[ -n "${_CMUX_BASH_HISTORY_LAST_FILE:-}" ]]; then
            printf '%s\n' "$history_number" > "$_CMUX_BASH_HISTORY_LAST_FILE" 2>/dev/null || true
        fi
        printf '%s\n' "${BASH_REMATCH[2]}"
        return 0
    fi
    return 1
}

_cmux_bash_preexec_hook() {
    local cmd="${1:-}"
    local history_cmd=""
    history_cmd="$(_cmux_bash_history_command 2>/dev/null || true)"
    if [[ -n "$history_cmd" ]]; then
        cmd="$history_cmd"
    fi
    _cmux_preexec_command "$cmd"
}

_cmux_bash_preexec_hook_subshell() {
    local _CMUX_IN_PREEXEC=1
    _cmux_bash_preexec_hook "$@"
}

_cmux_prompt_command() {
    local last_status=$?
    _cmux_tmux_sync_cmux_environment

    local cmux_has_unix_socket=0
    _cmux_socket_is_unix && cmux_has_unix_socket=1
    (( cmux_has_unix_socket )) || _cmux_has_port_scan_transport || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0

    if [[ -z "$_CMUX_TTY_NAME" ]]; then
        local t
        t="$(tty 2>/dev/null || true)"
        t="${t##*/}"
        [[ "$t" != "not a tty" ]] && _CMUX_TTY_NAME="$t"
    fi

    if [[ -n "$CMUX_PANEL_ID" ]]; then
        _cmux_reset_terminal_keyboard_protocols
    fi
    if [[ -n "$CMUX_PANEL_ID" ]] || (( ! cmux_has_unix_socket )); then
        _cmux_report_shell_activity_state prompt
    fi
    _cmux_report_tty_once

    local now
    now="$(_cmux_now)"
    local pwd="$PWD"
    if (( ! cmux_has_unix_socket )); then
        if [[ "$pwd" != "$_CMUX_PWD_LAST_PWD" ]]; then
            _cmux_report_pwd_via_relay "$pwd" && _CMUX_PWD_LAST_PWD="$pwd"
        fi
    else
        [[ -n "$CMUX_PANEL_ID" ]] || return 0
    fi

    _cmux_set_git_active_pwd "$pwd"

    # Post-wake socket writes can occasionally leave a probe process wedged.
    # If one probe is stale, clear the guard so fresh async probes can resume.
    if [[ -n "$_CMUX_GIT_JOB_PID" ]]; then
        if ! kill -0 "$_CMUX_GIT_JOB_PID" 2>/dev/null; then
            _CMUX_GIT_JOB_PID=""
            _CMUX_GIT_JOB_STARTED_AT=0
        elif (( _CMUX_GIT_JOB_STARTED_AT > 0 )) && (( now - _CMUX_GIT_JOB_STARTED_AT >= _CMUX_ASYNC_JOB_TIMEOUT )); then
            _CMUX_GIT_JOB_PID=""
            _CMUX_GIT_JOB_STARTED_AT=0
        fi
    fi

    # Resolve TTY name once.
    if [[ -z "$_CMUX_TTY_NAME" ]]; then
        local t
        t="$(tty 2>/dev/null || true)"
        t="${t##*/}"
        [[ "$t" != "not a tty" ]] && _CMUX_TTY_NAME="$t"
    fi

    _cmux_report_tty_once

    # CWD: keep the app in sync with the actual shell directory.
    if (( cmux_has_unix_socket )) && [[ "$pwd" != "$_CMUX_PWD_LAST_PWD" ]]; then
        _CMUX_PWD_LAST_PWD="$pwd"
        local qpwd="${pwd//\"/\\\"}"
        _cmux_send_bg "report_pwd \"${qpwd}\" --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
    fi

    # Branch can change via aliases/tools while an older probe is still in flight.
    # Track .git/HEAD content so we can restart stale probes immediately.
    local git_head_changed=0
    if [[ "${CMUX_NO_GIT_WATCH:-}" == "1" ]]; then
        _cmux_stop_pr_poll_loop
        if [[ -n "$_CMUX_GIT_JOB_PID" ]] && kill -0 "$_CMUX_GIT_JOB_PID" 2>/dev/null; then
            kill "$_CMUX_GIT_JOB_PID" >/dev/null 2>&1 || true
        fi
        _CMUX_GIT_JOB_PID=""
        _CMUX_GIT_JOB_STARTED_AT=0
        _CMUX_GIT_HEAD_LAST_PWD=""
        _CMUX_GIT_HEAD_PATH=""
        _CMUX_GIT_HEAD_SIGNATURE=""
        _CMUX_GIT_LAST_PWD=""
        _CMUX_PR_FORCE=0
        _CMUX_LAST_PR_ACTION=""
        _CMUX_LAST_PR_TARGET=""
        _cmux_clear_pr_command_hint_file
    else
        if [[ "$pwd" != "$_CMUX_GIT_HEAD_LAST_PWD" ]]; then
            _CMUX_GIT_HEAD_LAST_PWD="$pwd"
            _CMUX_GIT_HEAD_PATH="$(_cmux_git_resolve_head_path "$pwd" 2>/dev/null || true)"
            _CMUX_GIT_HEAD_SIGNATURE=""
        fi
        if [[ -n "$_CMUX_GIT_HEAD_PATH" ]]; then
            local head_signature
            head_signature="$(_cmux_git_head_signature "$_CMUX_GIT_HEAD_PATH" 2>/dev/null || true)"
            if [[ -n "$head_signature" ]]; then
                if [[ -z "$_CMUX_GIT_HEAD_SIGNATURE" ]]; then
                    # The first observed HEAD value is just the session baseline.
                    # Treating it as a branch change clears restore-seeded PR badges
                    # before the first background probe can confirm the current PR.
                    _CMUX_GIT_HEAD_SIGNATURE="$head_signature"
                elif [[ "$head_signature" != "$_CMUX_GIT_HEAD_SIGNATURE" ]]; then
                    _CMUX_GIT_HEAD_SIGNATURE="$head_signature"
                    git_head_changed=1
                    # Also invalidate the PR poller so it refreshes with the new branch.
                    _CMUX_PR_FORCE=1
                fi
            fi
        fi
    fi

    # Git branch/dirty can change without a directory change (e.g. `git checkout`),
    # so update on every prompt (still async + de-duped by the running-job check).
    # When pwd changes (cd into a different repo), kill the old probe and start fresh
    # so the sidebar picks up the new branch immediately.
    if [[ "${CMUX_NO_GIT_WATCH:-}" != "1" && -n "$_CMUX_GIT_JOB_PID" ]] && kill -0 "$_CMUX_GIT_JOB_PID" 2>/dev/null; then
        if [[ "$pwd" != "$_CMUX_GIT_LAST_PWD" || "$git_head_changed" == "1" ]]; then
            kill "$_CMUX_GIT_JOB_PID" >/dev/null 2>&1 || true
            _CMUX_GIT_JOB_PID=""
            _CMUX_GIT_JOB_STARTED_AT=0
        fi
    fi

    if [[ "${CMUX_NO_GIT_WATCH:-}" != "1" ]] && { [[ -z "$_CMUX_GIT_JOB_PID" ]] || ! kill -0 "$_CMUX_GIT_JOB_PID" 2>/dev/null; }; then
        _CMUX_GIT_LAST_PWD="$pwd"
        _CMUX_GIT_LAST_RUN=$now
        _cmux_start_tracked_bg _CMUX_GIT_JOB_PID _cmux_report_git_branch_for_path "$pwd"
        _CMUX_GIT_JOB_STARTED_AT=$now
    fi

    if (( cmux_has_unix_socket )); then
        if [[ "$git_head_changed" == "1" ]]; then
            _cmux_pr_cache_clear
            _cmux_clear_pr_for_panel
        fi
        if [[ "${CMUX_NO_GIT_WATCH:-}" != "1" ]] && (( last_status == 0 )); then
            _cmux_emit_pr_command_hint
        else
            _CMUX_LAST_PR_ACTION=""
            _CMUX_LAST_PR_TARGET=""
            _cmux_clear_pr_command_hint_file
        fi
    fi

    # Ports: lightweight kick to the app's batched scanner every ~10s.
    if (( now - _CMUX_PORTS_LAST_RUN >= 10 )); then
        _cmux_ports_kick refresh
    fi
}

_cmux_install_prompt_command() {
    [[ -n "${_CMUX_PROMPT_INSTALLED:-}" ]] && return 0
    _CMUX_PROMPT_INSTALLED=1

    local decl
    decl="$(declare -p PROMPT_COMMAND 2>/dev/null || true)"
    if [[ "$decl" == "declare -a"* ]]; then
        local existing=0
        local item
        for item in "${PROMPT_COMMAND[@]}"; do
            [[ "$item" == "_cmux_prompt_command" ]] && existing=1 && break
        done
        if (( existing == 0 )); then
            PROMPT_COMMAND=("_cmux_prompt_command" "${PROMPT_COMMAND[@]}")
        fi
    else
        case ";$PROMPT_COMMAND;" in
            *";_cmux_prompt_command;"*) ;;
            *)
                if [[ -n "$PROMPT_COMMAND" ]]; then
                    PROMPT_COMMAND="_cmux_prompt_command;$PROMPT_COMMAND"
                else
                    PROMPT_COMMAND="_cmux_prompt_command"
                fi
                ;;
        esac
    fi

        if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
        if (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3) )); then
            builtin readonly _CMUX_BASH_PS0='${ _cmux_bash_preexec_hook; }'
        else
            builtin readonly _CMUX_BASH_PS0='$(_cmux_bash_preexec_hook_subshell >/dev/null)'
        fi
        if [[ "$PS0" != *"${_CMUX_BASH_PS0}"* ]]; then
            PS0=$PS0"${_CMUX_BASH_PS0}"
        fi
    fi
}

# Ensure Resources/bin is at the front of PATH, and remove the app's
# Contents/MacOS entry so the GUI cmux binary cannot shadow the CLI cmux.
# Shell init (.bashrc/.bash_profile) may prepend other dirs after launch.
_cmux_fix_path() {
    if [[ -n "${GHOSTTY_BIN_DIR:-}" ]]; then
        local gui_dir="${GHOSTTY_BIN_DIR%/}"
        local bin_dir="${gui_dir%/MacOS}/Resources/bin"
        if [[ -d "$bin_dir" ]]; then
            PATH="$(_cmux_path_prepend_unique_directory "$bin_dir" "${PATH-}" "$gui_dir")"
        fi
    fi
}
_cmux_fix_path
unset -f _cmux_fix_path

_cmux_detect_send_tool

_cmux_install_prompt_command

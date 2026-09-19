# cmux shell integration for zsh
# Injected automatically — do not source manually

# Socket sends exec a unix-socket-capable client in a detached child. The
# historical zsocket fast path (zmodload zsh/net/unix) never activated because
# that module does not exist (zsocket lives in zsh/net/socket). Enabling it
# would also lose response-based ordering between connections and introduce an
# unbounded blocked child. A future fast path still needs one connection per
# batch plus bounded response reads.

typeset -g _CMUX_HAS_ZSH_JOBSTATES=0
if zmodload zsh/parameter 2>/dev/null && (( ${+jobstates} )); then
    _CMUX_HAS_ZSH_JOBSTATES=1
fi

_cmux_zsh_job_table_saturated() {
    (( _CMUX_HAS_ZSH_JOBSTATES )) || return 1

    local limit="${CMUX_ZSH_JOB_TABLE_SOFT_LIMIT:-900}"
    case "$limit" in
        ''|*[!0-9]*) limit=900 ;;
    esac
    (( limit > 0 )) || limit=900

    local job_count=${#jobstates}
    (( job_count >= limit ))
}

_cmux_restore_status() {
    builtin return "$1"
}

# BSD nc at /usr/bin/nc is preferred: it always supports -U, it waits for the
# server to process the line and close (which preserves send order across a
# batched child), and -w bounds its lifetime. PATH `nc` cannot be trusted first:
# GNU netcat (e.g. Homebrew in /usr/local/bin) lacks -U and fails silently,
# which dropped every hook message (report_tty, ports_kick, report_shell_state)
# on machines where it shadows the system nc. The capability envelope keeps
# the detached client authorized even after launchd or tmux reparents it.
_cmux_write_socket_payload() {
    local payload="$1"
    case "${CMUX_SOCKET_CAPABILITY:-}" in
        ""|*[[:space:]]*)
            print -r -- "$payload"
            ;;
        *)
            print -r -- "_cmux_capability_v1 $CMUX_SOCKET_CAPABILITY $payload"
            ;;
    esac
}

_cmux_send() {
    local payload="$1"
    if [[ -x /usr/bin/nc ]]; then
        # Apple's nc defines -N as `num_probes` (it is not OpenBSD's no-arg
        # shutdown-after-EOF flag), so the -N form fails option parsing; use
        # the bounded -w form directly. nc waits for the server to process the
        # line and close, preserving order in a batched child.
        _cmux_write_socket_payload "$payload" | /usr/bin/nc -w 1 -U "$CMUX_SOCKET_PATH" >/dev/null 2>&1 || true
        return 0
    fi
    if command -v ncat >/dev/null 2>&1; then
        _cmux_write_socket_payload "$payload" | ncat -w 1 -U "$CMUX_SOCKET_PATH" --send-only
    elif command -v socat >/dev/null 2>&1; then
        _cmux_write_socket_payload "$payload" | socat -T 1 - "UNIX-CONNECT:$CMUX_SOCKET_PATH" >/dev/null 2>&1
    elif command -v nc >/dev/null 2>&1; then
        if _cmux_write_socket_payload "$payload" | nc -N -U "$CMUX_SOCKET_PATH" >/dev/null 2>&1; then
            :
        else
            _cmux_write_socket_payload "$payload" | nc -w 1 -U "$CMUX_SOCKET_PATH" >/dev/null 2>&1 || true
        fi
    fi
}

# Fire-and-forget send, always detached from the interactive shell: the
# client's connect and response wait must never run in the foreground, or a
# wedged cmux listener (hung app, full backlog, post-wake socket) blocks every
# precmd/preexec hook and freezes the user's prompt. Each child self-bounds
# via its client timeout (-w 1 / -T 1), so a wedged listener cannot
# accumulate children beyond roughly one second's worth of sends.
# Accepts multiple payloads: they are sent sequentially inside ONE child, so
# callers with an ordering dependency between two messages (report_tty before
# ports_kick) batch them instead of racing two independent children.
# Returns nonzero when the payload was dropped (job-table saturation) so
# callers with edge-triggered latches can leave them unset and retry.
_cmux_send_bg() {
    _cmux_zsh_job_table_saturated && return 1
    {
        local _cmux_msg
        for _cmux_msg in "$@"; do
            _cmux_send "$_cmux_msg"
        done
    } >/dev/null 2>&1 &!
    return 0
}

_cmux_socket_is_unix() {
    [[ -n "$CMUX_SOCKET_PATH" && -S "$CMUX_SOCKET_PATH" ]]
}

_cmux_relay_cli_path() {
    if [[ -n "${CMUX_BUNDLED_CLI_PATH:-}" && -x "${CMUX_BUNDLED_CLI_PATH}" ]]; then
        print -r -- "${CMUX_BUNDLED_CLI_PATH}"
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
    print -r -- "$value"
}

_cmux_relay_rpc_bg() {
    local method="$1"
    local params="$2"
    local relay_cli=""
    _cmux_zsh_job_table_saturated && return 1
    _cmux_socket_uses_remote_relay || return 1
    relay_cli="$(_cmux_relay_cli_path)" || return 1
    { "$relay_cli" rpc "$method" "$params" >/dev/null 2>&1 || true } >/dev/null 2>&1 &!
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
        print -r -- "$CMUX_WORKSPACE_ID"
        return 0
    fi
    [[ -n "$CMUX_TAB_ID" ]] || return 1
    print -r -- "$CMUX_TAB_ID"
}

_cmux_report_tty_via_relay() {
    _cmux_socket_uses_remote_relay || return 1
    local workspace_id=""
    workspace_id="$(_cmux_relay_workspace_id)" || return 1
    [[ -n "$_CMUX_TTY_NAME" ]] || return 1
    [[ -n "$CMUX_TERMINAL_LIFECYCLE_ID" && -n "$CMUX_SSH_ATTEMPT_ID" ]] || return 1

    local tty_name_json params
    tty_name_json="$(_cmux_json_escape "$_CMUX_TTY_NAME")"
    params="{\"workspace_id\":\"$workspace_id\",\"tty_name\":\"$tty_name_json\",\"terminal_lifecycle_id\":\"$CMUX_TERMINAL_LIFECYCLE_ID\",\"attempt_id\":\"$CMUX_SSH_ATTEMPT_ID\""
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
    if [[ -n "${CMUX_TERMINAL_LIFECYCLE_ID:-}" ]]; then
        params+=",\"terminal_lifecycle_id\":\"$CMUX_TERMINAL_LIFECYCLE_ID\""
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
    local token="${path:t}"

    builtin printf '\033]1337;CurrentDir=kitty-shell-cwd://%s/.cmux/session-scrollback-replay/%s/start\007' "$HOST" "$token"

    if [[ -r "$path" ]]; then
        /bin/cat -- "$path" 2>/dev/null || true
        /bin/rm -f -- "$path" >/dev/null 2>&1 || true
    fi

    # Valid kitty-shell-cwd URIs reach Ghostty's PWD action in PTY order. The
    # following real cwd report keeps the private boundary out of title state.
    builtin printf '\033]1337;CurrentDir=kitty-shell-cwd://%s/.cmux/session-scrollback-replay/%s/end\007' "$HOST" "$token"
    builtin printf '\033]1337;CurrentDir=kitty-shell-cwd://%s%s\007' "$HOST" "$PWD"
}
_cmux_restore_scrollback_once

_cmux_now() {
    print -r -- "${EPOCHSECONDS:-$SECONDS}"
}

typeset -g _CMUX_CLAUDE_WRAPPER=""
typeset -g _CMUX_GROK_WRAPPER=""
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
    local surface_component="${CMUX_SURFACE_ID:-$$}"
    local shim_root="${CMUX_CLAUDE_WRAPPER_SHIM_ROOT:-}"
    local shim_parent="${shim_root%/*}"
    if [[ -z "$shim_root" || "${shim_root##*/}" != "$surface_component" || "${shim_parent##*/}" != "cmux-cli-shims" ]]; then
        shim_root="${TMPDIR:-/tmp}/cmux-cli-shims/$surface_component"
    fi
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
    # Use zsh's explicit clobber redirection (>|) so cmux always refreshes its
    # own generated shim, even when the user's interactive zsh has `noclobber`
    # set. A plain `>` is refused under noclobber and prints `file exists` on
    # startup (the writer runs again from the _cmux_fix_path precmd hook after
    # the shim already exists). See issue #6714.
    } >|"$shim_path" 2>/dev/null || return 0
    /bin/chmod 0700 "$shim_path" >/dev/null 2>&1 || return 0

    if [[ "$command_name" == "claude" ]]; then
        export CMUX_CLAUDE_WRAPPER_SHIM="$shim_path"
        export CMUX_CLAUDE_WRAPPER_SHIM_ROOT="$shim_root"
    fi

    PATH="$(_cmux_path_prepend_unique_directory "$shim_root" "${PATH-}")"
    hash -r >/dev/null 2>&1 || rehash >/dev/null 2>&1 || true
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
    [[ -n "$integration_dir" ]] || return 0

    integration_dir="${integration_dir%/}"
    local bundle_dir="${integration_dir%/shell-integration}"
    local wrapper_path="$bundle_dir/bin/$wrapper_file"
    [[ -x "$wrapper_path" ]] || return 0

    # Keep the bundled wrapper ahead of later PATH mutations. Install it
    # via eval so an existing alias cannot break parsing.
    typeset -g "$wrapper_variable=$wrapper_path"
    if [[ "$command_name" == "claude" ]]; then
        _cmux_install_cli_command_shim "$command_name" "$wrapper_path"
    fi
    builtin unalias "$command_name" >/dev/null 2>&1 || true
    if [[ "$command_name" == "claude" ]]; then
        eval "$command_name() { _cmux_claude_wrapper_command \"\$@\"; }"
    else
        eval "$command_name() { \"\${$wrapper_variable}\" \"\$@\"; }"
    fi
}
_cmux_install_cli_wrapper claude _CMUX_CLAUDE_WRAPPER cmux-claude-wrapper
_cmux_install_cli_wrapper grok _CMUX_GROK_WRAPPER

_cmux_normalize_claude_config_dir() {
    [[ -n "${CLAUDE_CONFIG_DIR:-}" && -n "${HOME:-}" ]] || return 0

    local value="$CLAUDE_CONFIG_DIR"
    if [[ "$value" == "~/"* ]]; then
        value="$HOME/${value#~/}"
    fi

    local legacy_root="$HOME/.subrouter/codex/claude"
    local account_root="$HOME/.codex-accounts/claude"
    local suffix candidate

    if [[ "$value" == "$legacy_root" ]]; then
        candidate="$account_root"
    elif [[ "$value" == "$legacy_root/"* ]]; then
        suffix="${value#$legacy_root/}"
        candidate="$account_root/$suffix"
    else
        return 0
    fi

    [[ -d "$candidate" ]] || return 0
    export CLAUDE_CONFIG_DIR="$candidate"
}
_cmux_normalize_claude_config_dir

# Throttle heavy work to avoid prompt latency.
typeset -g _CMUX_PWD_LAST_PWD=""
typeset -g _CMUX_GIT_LAST_PWD=""
typeset -g _CMUX_GIT_LAST_RUN=0
typeset -g _CMUX_GIT_JOB_PID=""
typeset -g _CMUX_GIT_JOB_STARTED_AT=0
typeset -g _CMUX_GIT_FORCE=0
typeset -g _CMUX_GIT_HEAD_LAST_PWD=""
typeset -g _CMUX_GIT_HEAD_PATH=""
typeset -g _CMUX_GIT_HEAD_SIGNATURE=""
typeset -g _CMUX_GIT_HEAD_WATCH_PID=""
typeset -g _CMUX_GIT_ACTIVE_PWD_FILE="${_CMUX_GIT_ACTIVE_PWD_FILE:-$(/usr/bin/mktemp "${TMPDIR:-/tmp}/cmux-git-active-pwd.XXXXXX" 2>/dev/null || true)}"
typeset -g _CMUX_ASYNC_JOB_TIMEOUT=20
typeset -g _CMUX_LAST_PR_ACTION=""
typeset -g _CMUX_LAST_PR_TARGET=""

typeset -g _CMUX_PORTS_LAST_RUN=0
typeset -g _CMUX_CMD_START=0
typeset -g _CMUX_SHELL_ACTIVITY_LAST=""
typeset -g _CMUX_TTY_NAME=""
typeset -g _CMUX_TTY_REPORTED=0
typeset -g _CMUX_TMUX_PUSH_SIGNATURE=""
typeset -g _CMUX_TMUX_PULL_SIGNATURE=""
typeset -g _CMUX_DELAY_TERM_RESTORE_UNTIL_FIRST_PROMPT=${_CMUX_DELAY_TERM_RESTORE_UNTIL_FIRST_PROMPT:-0}
# Keep CMUX_SOCKET_CAPABILITY inherited; tmux's global environment is readable
# by clients that were not started inside cmux.
typeset -ga _CMUX_TMUX_SYNC_KEYS=(
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
    CMUX_SSH_ATTEMPT_ID
    CMUX_TAB_ID
    CMUX_TAG
    CMUX_TERMINAL_LIFECYCLE_ID
    CMUX_WORKSPACE_ID
)
typeset -ga _CMUX_TMUX_SURFACE_SCOPED_KEYS=(
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
    local key value
    local -a parts
    for key in "${_CMUX_TMUX_SYNC_KEYS[@]}"; do
        value="${(P)key}"
        [[ -n "$value" ]] || continue
        parts+=("${key}=${value}")
    done
    print -r -- "${(j:\x1f:)parts}"
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
        value="${(P)key}"
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

    local key did_change=0
    for key in "${_CMUX_TMUX_SURFACE_SCOPED_KEYS[@]}"; do
        if [[ -n "${(P)key}" ]]; then
            unset "$key"
            did_change=1
        fi
    done

    local output
    output="$(tmux show-environment 2>/dev/null)" || return 0

    local line filtered=""
    while IFS= read -r line; do
        [[ "$line" == CMUX_* ]] || continue
        key="${line%%=*}"
        _cmux_tmux_sync_key_is_managed "$key" || continue
        filtered+="${line}"$'\n'
    done <<< "$output"

    [[ -n "$filtered" ]] || return 0
    [[ "$filtered" == "$_CMUX_TMUX_PULL_SIGNATURE" ]] && (( ! did_change )) && return 0

    local value
    while IFS= read -r line; do
        [[ "$line" == CMUX_* ]] || continue
        key="${line%%=*}"
        _cmux_tmux_sync_key_is_managed "$key" || continue
        value="${line#*=}"
        if [[ "${(P)key}" != "$value" ]]; then
            export "$key=$value"
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
        _CMUX_GIT_FORCE=1
        _cmux_stop_git_head_watch
    fi
}

_cmux_tmux_sync_cmux_environment() {
    if [[ -n "$TMUX" ]]; then
        _cmux_tmux_refresh_cmux_environment
    else
        _cmux_tmux_publish_cmux_environment
    fi
}

_cmux_prepend_job_table_guard_to_function() {
    local fn_name="$1"
    (( $+functions[$fn_name] )) || return 0
    local saved_var="__cmux_${fn_name}_saved_status"
    [[ "${functions[$fn_name]}" == *"$saved_var"* ]] && return 0

    functions[$fn_name]="builtin local ${saved_var}=\$?
_cmux_zsh_job_table_saturated && builtin return 0
_cmux_restore_status \"\$${saved_var}\"
${functions[$fn_name]}"
}

_cmux_insert_job_table_guard_after_declaration() {
    builtin emulate -L zsh -o extended_glob -o no_aliases

    local fn_name="$1"
    local target_name="$2"
    local guard="$3"
    (( $+functions[$fn_name] )) || return 0

    local body="${functions[$fn_name]}"
    [[ "$body" == *"$guard"* ]] && return 0

    local -a lines patched_lines declaration_names
    lines=("${(@f)body}")
    local line trimmed declaration candidate
    local inserted=0

    for line in "${lines[@]}"; do
        patched_lines+=("$line")
        (( inserted )) && continue

        trimmed="${line##[[:space:]]#}"
        [[ "$trimmed" == *"{"* ]] || continue

        declaration="${trimmed%%\{}"
        declaration="${declaration//\(\)/ }"
        if [[ "$declaration" == function[[:space:]]* ]]; then
            declaration="${declaration#function}"
        fi
        declaration_names=("${(@z)declaration}")

        for candidate in "${declaration_names[@]}"; do
            if [[ "$candidate" == "$target_name" ]]; then
                patched_lines+=("${(@f)guard}")
                inserted=1
                break
            fi
        done
    done

    (( inserted )) || return 0
    functions[$fn_name]="${(F)patched_lines}"
}

_cmux_patch_ghostty_job_table_guard() {
    local guard_precmd=$'        builtin local __cmux__ghostty_precmd_saved_status=$?\n        _cmux_zsh_job_table_saturated && builtin return 0\n        _cmux_restore_status "$__cmux__ghostty_precmd_saved_status"'
    local guard_preexec=$'        builtin local __cmux__ghostty_preexec_saved_status=$?\n        _cmux_zsh_job_table_saturated && builtin return 0\n        _cmux_restore_status "$__cmux__ghostty_preexec_saved_status"'
    local guard_zle_init=$'          builtin local __cmux__ghostty_zle_line_init_saved_status=$?\n          _cmux_zsh_job_table_saturated && builtin return 0\n          _cmux_restore_status "$__cmux__ghostty_zle_line_init_saved_status"'
    local guard_zle_finish=$'          builtin local __cmux__ghostty_zle_line_finish_saved_status=$?\n          _cmux_zsh_job_table_saturated && builtin return 0\n          _cmux_restore_status "$__cmux__ghostty_zle_line_finish_saved_status"'
    local guard_zle_keymap=$'          builtin local __cmux__ghostty_zle_keymap_select_saved_status=$?\n          _cmux_zsh_job_table_saturated && builtin return 0\n          _cmux_restore_status "$__cmux__ghostty_zle_keymap_select_saved_status"'

    # Patch deferred definitions before Ghostty's first precmd installs and
    # invokes its live hook functions.
    if (( $+functions[_ghostty_deferred_init] )); then
        _cmux_insert_job_table_guard_after_declaration _ghostty_deferred_init _ghostty_precmd "$guard_precmd"
        _cmux_insert_job_table_guard_after_declaration _ghostty_deferred_init _ghostty_preexec "$guard_preexec"
        _cmux_insert_job_table_guard_after_declaration _ghostty_deferred_init _ghostty_zle_line_init "$guard_zle_init"
        _cmux_insert_job_table_guard_after_declaration _ghostty_deferred_init _ghostty_zle_line_finish "$guard_zle_finish"
        _cmux_insert_job_table_guard_after_declaration _ghostty_deferred_init _ghostty_zle_keymap_select "$guard_zle_keymap"
    fi

    _cmux_prepend_job_table_guard_to_function _ghostty_precmd
    _cmux_prepend_job_table_guard_to_function _ghostty_preexec
    _cmux_prepend_job_table_guard_to_function _ghostty_zle_line_init
    _cmux_prepend_job_table_guard_to_function _ghostty_zle_line_finish
    _cmux_prepend_job_table_guard_to_function _ghostty_zle_keymap_select
}
_cmux_patch_ghostty_job_table_guard

_cmux_git_resolve_head_path() {
    # Resolve the HEAD file path without invoking git (fast; works for worktrees).
    local dir="${1:-$PWD}"
    while true; do
        if [[ -d "$dir/.git" ]]; then
            print -r -- "$dir/.git/HEAD"
            return 0
        fi
        if [[ -f "$dir/.git" ]]; then
            local line gitdir
            line="$(<"$dir/.git")"
            if [[ "$line" == gitdir:* ]]; then
                gitdir="${line#gitdir:}"
                gitdir="${gitdir## }"
                gitdir="${gitdir%% }"
                [[ -n "$gitdir" ]] || return 1
                [[ "$gitdir" != /* ]] && gitdir="$dir/$gitdir"
                print -r -- "$gitdir/HEAD"
                return 0
            fi
        fi
        [[ "$dir" == "/" || -z "$dir" ]] && break
        dir="${dir:h}"
    done
    return 1
}

_cmux_git_resolve_git_dir() {
    local repo_path="${1:-$PWD}"
    local head_path
    head_path="$(_cmux_git_resolve_head_path "$repo_path" 2>/dev/null || true)"
    [[ -n "$head_path" ]] || return 1
    print -r -- "${head_path:h}"
}

_cmux_git_head_signature() {
    local head_path="$1"
    [[ -n "$head_path" && -r "$head_path" ]] || return 1
    local line=""
    if IFS= read -r line < "$head_path"; then
        print -r -- "$line"
        return 0
    fi
    return 1
}

_cmux_git_branch_for_path() {
    local repo_path="$1"
    local head_path="" head_line="" prefix="ref: refs/heads/"
    head_path="$(_cmux_git_resolve_head_path "$repo_path" 2>/dev/null || true)"
    [[ -n "$head_path" && -r "$head_path" ]] || return 1
    head_line="$(<"$head_path")"
    [[ "$head_line" == "$prefix"* ]] || return 1
    print -r -- "${head_line#$prefix}"
}

_cmux_set_git_active_pwd() {
    local active_pwd="$1"
    [[ -n "$active_pwd" ]] || return 0
    [[ -n "${_CMUX_GIT_ACTIVE_PWD_FILE:-}" ]] || return 0
    print -r -- "$active_pwd" >| "$_CMUX_GIT_ACTIVE_PWD_FILE" 2>/dev/null || true
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
    # in-repo `cd pkg` (the HEAD watch still reports the preexec watch_pwd) while
    # still dropping a report once the shell has left the repo entirely (the
    # stale-branch case). Resolve both HEAD paths without invoking git and compare.
    local repo_head active_head
    repo_head="$(_cmux_git_resolve_head_path "$repo_path" 2>/dev/null || true)"
    active_head="$(_cmux_git_resolve_head_path "$active_pwd" 2>/dev/null || true)"
    [[ -n "$repo_head" && "$repo_head" == "$active_head" ]]
}

_cmux_report_tty_payload() {
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$_CMUX_TTY_NAME" ]] || return 0

    local payload="report_tty $_CMUX_TTY_NAME --tab=$CMUX_TAB_ID"
    if [[ -z "$TMUX" ]]; then
        [[ -n "$CMUX_PANEL_ID" ]] || return 0
        payload+=" --panel=$CMUX_PANEL_ID"
    fi

    print -r -- "$payload"
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
        # Batch the first ports kick behind the registration in the same
        # child: the scanner drops kicks for unregistered TTYs, and two
        # detached children can connect out of order. Latch only after the
        # send was actually enqueued so a cap-dropped registration retries.
        if [[ -n "$CMUX_TAB_ID" && -n "$CMUX_PANEL_ID" ]]; then
            _cmux_send_bg "$payload" "ports_kick --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID --reason=command" || return 0
        else
            _cmux_send_bg "$payload" || return 0
        fi
        _CMUX_TTY_REPORTED=1
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
        local payload="report_shell_state $state --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
        if [[ -n "${CMUX_TERMINAL_LIFECYCLE_ID:-}" ]]; then
            payload+=" --terminal-lifecycle-id=$CMUX_TERMINAL_LIFECYCLE_ID"
        fi
        _cmux_send_bg "$payload" \
            || _CMUX_SHELL_ACTIVITY_LAST=""
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

_cmux_record_pr_command_hint() {
    local cmd="$1"
    _CMUX_LAST_PR_ACTION=""
    _CMUX_LAST_PR_TARGET=""

    local -a words
    words=("${(z)cmd}")

    local index=1
    local word base
    while (( index <= ${#words} )); do
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
                while (( index <= ${#words} )); do
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

        base="${word:t}"
        [[ "$base" == "gh" ]] || return 0
        index=$(( index + 1 ))
        break
    done

    (( index + 1 <= ${#words} )) || return 0
    [[ "${words[index]}" == "pr" ]] || return 0
    local action="${words[index + 1]:l}"
    case "$action" in
        merge|close|reopen|create|checkout|ready|edit|view)
            _CMUX_LAST_PR_ACTION="$action" ;;
        *)
            return 0 ;;
    esac

    index=$(( index + 2 ))
    while (( index <= ${#words} )); do
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
}

_cmux_emit_pr_command_hint() {
    [[ "${CMUX_NO_PR_WATCH:-}" == "1" ]] && return 0
    [[ -S "$CMUX_SOCKET_PATH" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$CMUX_PANEL_ID" ]] || return 0
    [[ -n "$_CMUX_LAST_PR_ACTION" ]] || return 0

    local payload="report_pr_action $_CMUX_LAST_PR_ACTION --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
    if [[ -n "$_CMUX_LAST_PR_TARGET" ]]; then
        local quoted_target="${_CMUX_LAST_PR_TARGET//\"/\\\"}"
        payload+=" --target=\"$quoted_target\""
    fi
    _cmux_send_bg "$payload"
    _CMUX_LAST_PR_ACTION=""
    _CMUX_LAST_PR_TARGET=""
}

_cmux_clear_pr_for_panel() {
    [[ "${CMUX_NO_GIT_WATCH:-}" == "1" ]] && return 0
    [[ -S "$CMUX_SOCKET_PATH" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$CMUX_PANEL_ID" ]] || return 0
    _cmux_send_bg "clear_pr --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
}

_cmux_stop_git_head_watch() {
    [[ -n "$_CMUX_GIT_HEAD_WATCH_PID" ]] || return 0
    kill "$_CMUX_GIT_HEAD_WATCH_PID" >/dev/null 2>&1 || true
    _CMUX_GIT_HEAD_WATCH_PID=""
}

_cmux_start_git_head_watch() {
    [[ "${CMUX_NO_GIT_WATCH:-}" == "1" ]] && return 0
    [[ -S "$CMUX_SOCKET_PATH" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$CMUX_PANEL_ID" ]] || return 0
    _cmux_zsh_job_table_saturated && return 0

    local watch_pwd="$PWD"
    local watch_head_path
    watch_head_path="$(_cmux_git_resolve_head_path "$watch_pwd" 2>/dev/null || true)"
    [[ -n "$watch_head_path" ]] || return 0

    local watch_head_signature
    watch_head_signature="$(_cmux_git_head_signature "$watch_head_path" 2>/dev/null || true)"

    _CMUX_GIT_HEAD_LAST_PWD="$watch_pwd"
    _CMUX_GIT_HEAD_PATH="$watch_head_path"
    _CMUX_GIT_HEAD_SIGNATURE="$watch_head_signature"

    _cmux_stop_git_head_watch
    local watch_shell_pid="$$"
    {
        local last_signature="$watch_head_signature"
        while true; do
            kill -0 "$watch_shell_pid" >/dev/null 2>&1 || break
            sleep 1

            local signature
            signature="$(_cmux_git_head_signature "$watch_head_path" 2>/dev/null || true)"
            if [[ -n "$signature" && "$signature" != "$last_signature" ]]; then
                last_signature="$signature"
                _cmux_report_git_branch_for_path "$watch_pwd"
                _cmux_clear_pr_for_panel
            fi
        done
    } >/dev/null 2>&1 &!
    _CMUX_GIT_HEAD_WATCH_PID=$!
}

_cmux_command_starts_nested_shell() {
    local cmd="$1"
    local -a words
    words=("${(z)cmd}")

    local index=1
    local word base
    while (( index <= ${#words} )); do
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
                while (( index <= ${#words} )); do
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

        base="${word:t}"
        case "$base" in
            bash|zsh|sh|fish|nu|nix-shell)
                return 0 ;;
            nix)
                local next_index=$(( index + 1 ))
                local next_word="${words[next_index]}"
                case "$next_word" in
                    develop|shell)
                        return 0 ;;
                esac ;;
        esac

        return 1
    done

    return 1
}

_cmux_preexec() {
    local cmd="${1## }"
    _cmux_stop_git_head_watch
    _cmux_zsh_job_table_saturated && return 0

    _cmux_normalize_claude_config_dir
    if (( ! _CMUX_DELAY_TERM_RESTORE_UNTIL_FIRST_PROMPT )); then
        _cmux_restore_terminal_identity_after_startup
    fi
    _cmux_tmux_sync_cmux_environment

    if [[ -z "$_CMUX_TTY_NAME" ]]; then
        local t
        t="$(tty 2>/dev/null || true)"
        t="${t##*/}"
        [[ -n "$t" && "$t" != "not a tty" ]] && _CMUX_TTY_NAME="$t"
    fi

    _CMUX_CMD_START="$(_cmux_now)"
    _cmux_report_shell_activity_state running
    _cmux_record_pr_command_hint "$cmd"

    # Heuristic: commands that may change git branch/dirty state without changing $PWD.
    case "$cmd" in
        git\ *|git|gh\ *|lazygit|lazygit\ *|tig|tig\ *|gitui|gitui\ *|stg\ *|jj\ *)
            _CMUX_GIT_FORCE=1 ;;
    esac

    # Register TTY + kick batched port scan for foreground commands (servers).
    _cmux_report_tty_once
    _cmux_ports_kick command
    if _cmux_command_starts_nested_shell "$cmd"; then
        return 0
    fi
    _cmux_start_git_head_watch
}

_cmux_precmd() {
    local last_status=$?
    # Ghostty integration can initialize after this file, so retry its job-table
    # guards when each prompt begins.
    _cmux_patch_ghostty_job_table_guard
    _cmux_stop_git_head_watch
    _cmux_zsh_job_table_saturated && return 0

    _cmux_normalize_claude_config_dir
    if (( _CMUX_DELAY_TERM_RESTORE_UNTIL_FIRST_PROMPT )); then
        _CMUX_DELAY_TERM_RESTORE_UNTIL_FIRST_PROMPT=0
    fi
    _cmux_tmux_sync_cmux_environment

    local cmux_has_unix_socket=0
    _cmux_socket_is_unix && cmux_has_unix_socket=1
    (( cmux_has_unix_socket )) || _cmux_has_port_scan_transport || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    if [[ -n "$CMUX_PANEL_ID" ]]; then
        _cmux_reset_terminal_keyboard_protocols
    fi
    if [[ -n "$CMUX_PANEL_ID" ]] || (( ! cmux_has_unix_socket )); then
        _cmux_report_shell_activity_state prompt
    fi

    if [[ -z "$_CMUX_TTY_NAME" ]]; then
        local t
        t="$(tty 2>/dev/null || true)"
        t="${t##*/}"
        [[ -n "$t" && "$t" != "not a tty" ]] && _CMUX_TTY_NAME="$t"
    fi

    _cmux_report_tty_once

    local now="$(_cmux_now)"
    local cmd_start="$_CMUX_CMD_START"
    _CMUX_CMD_START=0
    local pwd="$PWD"
    local cmd_dur=0
    if [[ -n "$cmd_start" && "$cmd_start" != 0 ]]; then
        cmd_dur=$(( now - cmd_start ))
    fi

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
            _CMUX_GIT_FORCE=1
        fi
    fi

    # CWD: keep the app in sync with the actual shell directory.
    # This is also the simplest way to test sidebar directory behavior end-to-end.
    if (( cmux_has_unix_socket )) && [[ "$pwd" != "$_CMUX_PWD_LAST_PWD" ]]; then
        _CMUX_PWD_LAST_PWD="$pwd"
        local qpwd="${pwd//\"/\\\"}"
        _cmux_send_bg "report_pwd \"${qpwd}\" --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
    fi

    # Git branch/dirty: update immediately on directory change, otherwise every ~3s.
    # While a foreground command is running, _cmux_start_git_head_watch probes HEAD
    # once per second so agent-initiated git checkouts still surface quickly.
    local should_git=0
    local git_head_changed=0

    # Git branch can change without a `git ...`-prefixed command (aliases like `gco`,
    # tools like `gh pr checkout`, etc.). Detect HEAD changes and force a refresh.
    if [[ "${CMUX_NO_GIT_WATCH:-}" == "1" ]]; then
        _cmux_stop_git_head_watch
        if [[ -n "$_CMUX_GIT_JOB_PID" ]] && kill -0 "$_CMUX_GIT_JOB_PID" 2>/dev/null; then
            kill "$_CMUX_GIT_JOB_PID" >/dev/null 2>&1 || true
        fi
        _CMUX_GIT_JOB_PID=""
        _CMUX_GIT_JOB_STARTED_AT=0
        _CMUX_GIT_FORCE=0
        _CMUX_GIT_HEAD_LAST_PWD=""
        _CMUX_GIT_HEAD_PATH=""
        _CMUX_GIT_HEAD_SIGNATURE=""
        _CMUX_GIT_LAST_PWD=""
        _CMUX_LAST_PR_ACTION=""
        _CMUX_LAST_PR_TARGET=""
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
                    # The first observed HEAD value establishes the baseline for this
                    # shell session. Don't treat it as a branch change or we'll clear
                    # restore-seeded PR badges before the first background probe runs.
                    _CMUX_GIT_HEAD_SIGNATURE="$head_signature"
                elif [[ "$head_signature" != "$_CMUX_GIT_HEAD_SIGNATURE" ]]; then
                    _CMUX_GIT_HEAD_SIGNATURE="$head_signature"
                    git_head_changed=1
                    # Treat HEAD file change like a git command — force-replace any
                    # running probe so the sidebar picks up the new branch immediately.
                    _CMUX_GIT_FORCE=1
                    should_git=1
                fi
            fi
        fi
    fi

    if [[ "$pwd" != "$_CMUX_GIT_LAST_PWD" ]]; then
        should_git=1
    elif (( _CMUX_GIT_FORCE )); then
        should_git=1
    elif (( now - _CMUX_GIT_LAST_RUN >= 3 )); then
        should_git=1
    fi

    if [[ "${CMUX_NO_GIT_WATCH:-}" != "1" ]] && (( should_git )); then
        local can_launch_git=1
        if [[ -n "$_CMUX_GIT_JOB_PID" ]] && kill -0 "$_CMUX_GIT_JOB_PID" 2>/dev/null; then
            # If a stale probe is still running but the cwd changed (or we just ran
            # a git command), restart immediately so branch state isn't delayed
            # until the next user command/prompt.
            # Note: this repeats the cwd check above on purpose. The first check
            # decides whether we should refresh at all; this one decides whether
            # an in-flight older probe can be reused vs. replaced.
            if [[ "$pwd" != "$_CMUX_GIT_LAST_PWD" ]] || (( _CMUX_GIT_FORCE )); then
                kill "$_CMUX_GIT_JOB_PID" >/dev/null 2>&1 || true
                _CMUX_GIT_JOB_PID=""
                _CMUX_GIT_JOB_STARTED_AT=0
            else
                can_launch_git=0
            fi
        fi

        if (( can_launch_git )); then
            _CMUX_GIT_FORCE=0
            _CMUX_GIT_LAST_PWD="$pwd"
            _CMUX_GIT_LAST_RUN=$now
            {
                _cmux_report_git_branch_for_path "$pwd"
            } >/dev/null 2>&1 &!
            _CMUX_GIT_JOB_PID=$!
            _CMUX_GIT_JOB_STARTED_AT=$now
        fi
    fi
    if (( cmux_has_unix_socket )); then
        if (( git_head_changed )); then
            _cmux_clear_pr_for_panel
        fi
        if [[ "${CMUX_NO_GIT_WATCH:-}" != "1" ]] && (( last_status == 0 )); then
            _cmux_emit_pr_command_hint
        else
            _CMUX_LAST_PR_ACTION=""
            _CMUX_LAST_PR_TARGET=""
        fi
    fi

    # Ports: lightweight kick to the app's batched scanner.
    # - Periodic scan to avoid stale values.
    # - Forced scan when a long-running command returns to the prompt (common when stopping a server).
    if (( cmd_dur >= 2 || now - _CMUX_PORTS_LAST_RUN >= 10 )); then
        _cmux_ports_kick refresh
    fi
}

# Ensure Resources/bin is at the front of PATH, and remove the app's
# Contents/MacOS entry so the GUI cmux binary cannot shadow the CLI cmux.
# Shell init (.zprofile/.zshrc) may prepend other dirs after launch.
# We fix this once on first prompt (after all init files have run), and
# reinstall cmux-owned wrapper functions in case user startup replaced them.
_cmux_fix_path() {
    local integration_dir="${CMUX_SHELL_INTEGRATION_DIR:-}"
    integration_dir="${integration_dir%/}"
    if [[ "$integration_dir" == */Resources/shell-integration ]]; then
        local resources_dir="${integration_dir%/shell-integration}"
        local gui_dir="${resources_dir%/Resources}/MacOS"
        local bin_dir="$resources_dir/bin"
        if [[ -d "$bin_dir" ]]; then
            PATH="$(_cmux_path_prepend_unique_directory "$bin_dir" "${PATH-}" "$gui_dir")"
        fi
    fi
    _cmux_install_cli_wrapper claude _CMUX_CLAUDE_WRAPPER cmux-claude-wrapper
    _cmux_install_cli_wrapper grok _CMUX_GROK_WRAPPER
    add-zsh-hook -d precmd _cmux_fix_path
}

_cmux_chpwd() {
    # Only refresh the active-cwd marker so async git reporters (the HEAD-watch
    # loop and deferred prompt probes) are scoped to the new cwd. Do NOT tear the
    # HEAD watch down here: chpwd fires mid-line for compound commands such as
    # `cd foo && pnpm dev`, and killing the watcher would drop live branch updates
    # during the long-running step. The marker guard already suppresses any stale
    # report for the path the shell just left, and precmd stops the watch at the
    # next prompt.
    _cmux_set_git_active_pwd "$PWD"
}

_cmux_restore_terminal_identity_after_startup() {
    if [[ -n "${CMUX_ZSH_RESTORE_TERM:-}" ]]; then
        builtin export TERM="$CMUX_ZSH_RESTORE_TERM"
        builtin unset CMUX_ZSH_RESTORE_TERM
    fi
    _CMUX_DELAY_TERM_RESTORE_UNTIL_FIRST_PROMPT=0
}

_cmux_zshexit() {
    _cmux_stop_git_head_watch
    [[ -n "${_CMUX_GIT_ACTIVE_PWD_FILE:-}" ]] && /bin/rm -f -- "$_CMUX_GIT_ACTIVE_PWD_FILE" >/dev/null 2>&1 || true
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _cmux_preexec
add-zsh-hook precmd _cmux_precmd
add-zsh-hook precmd _cmux_fix_path
add-zsh-hook chpwd _cmux_chpwd
add-zsh-hook zshexit _cmux_zshexit

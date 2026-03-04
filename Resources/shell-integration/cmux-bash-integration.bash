# cmux shell integration for bash

_cmux_send() {
    local payload="$1"
    if command -v ncat >/dev/null 2>&1; then
        printf '%s\n' "$payload" | ncat -w 1 -U "$CMUX_SOCKET_PATH" --send-only
    elif command -v socat >/dev/null 2>&1; then
        printf '%s\n' "$payload" | socat -T 1 - "UNIX-CONNECT:$CMUX_SOCKET_PATH"
    elif command -v nc >/dev/null 2>&1; then
        # Some nc builds don't support unix sockets, but keep as a last-ditch fallback.
        #
        # Important: macOS/BSD nc will often wait for the peer to close the socket
        # after it has finished writing. cmux keeps the connection open, so
        # a plain `nc -U` can hang indefinitely and leak background processes.
        #
        # Prefer flags that guarantee we exit after sending, and fall back to a
        # short timeout so we never block sidebar updates.
        if printf '%s\n' "$payload" | nc -N -U "$CMUX_SOCKET_PATH" >/dev/null 2>&1; then
            :
        else
            printf '%s\n' "$payload" | nc -w 1 -U "$CMUX_SOCKET_PATH" >/dev/null 2>&1 || true
        fi
    fi
}

_cmux_restore_scrollback_once() {
    local path="${CMUX_RESTORE_SCROLLBACK_FILE:-}"
    [[ -n "$path" ]] || return 0
    unset CMUX_RESTORE_SCROLLBACK_FILE

    if [[ -r "$path" ]]; then
        /bin/cat -- "$path" 2>/dev/null || true
        /bin/rm -f -- "$path" >/dev/null 2>&1 || true
    fi
}
_cmux_restore_scrollback_once

# Throttle heavy work to avoid prompt latency.
_CMUX_PWD_LAST_PWD="${_CMUX_PWD_LAST_PWD:-}"
_CMUX_GIT_LAST_PWD="${_CMUX_GIT_LAST_PWD:-}"
_CMUX_GIT_LAST_RUN="${_CMUX_GIT_LAST_RUN:-0}"
_CMUX_GIT_JOB_PID="${_CMUX_GIT_JOB_PID:-}"
_CMUX_GIT_JOB_STARTED_AT="${_CMUX_GIT_JOB_STARTED_AT:-0}"
_CMUX_PR_LAST_PWD="${_CMUX_PR_LAST_PWD:-}"
_CMUX_PR_LAST_RUN="${_CMUX_PR_LAST_RUN:-0}"
_CMUX_PR_JOB_PID="${_CMUX_PR_JOB_PID:-}"
_CMUX_PR_JOB_STARTED_AT="${_CMUX_PR_JOB_STARTED_AT:-0}"
_CMUX_ASYNC_JOB_TIMEOUT="${_CMUX_ASYNC_JOB_TIMEOUT:-20}"

_CMUX_PORTS_LAST_RUN="${_CMUX_PORTS_LAST_RUN:-0}"
_CMUX_TTY_NAME="${_CMUX_TTY_NAME:-}"
_CMUX_TTY_REPORTED="${_CMUX_TTY_REPORTED:-0}"
_CMUX_TMUX_CONTEXT_KEY="${_CMUX_TMUX_CONTEXT_KEY:-}"
_CMUX_TMUX_BRIDGE_LAST_RUN="${_CMUX_TMUX_BRIDGE_LAST_RUN:-0}"
_CMUX_TMUX_BRIDGE_SOCKET="${_CMUX_TMUX_BRIDGE_SOCKET:-}"
_CMUX_TMUX_LAUNCH_LAST_RUN="${_CMUX_TMUX_LAUNCH_LAST_RUN:-0}"
_CMUX_TMUX_LAUNCH_SOCKET="${_CMUX_TMUX_LAUNCH_SOCKET:-}"

_cmux_report_tty_once() {
    # Send the TTY name to the app once per session so the batched port scanner
    # knows which TTY belongs to this panel.
    (( _CMUX_TTY_REPORTED )) && return 0
    [[ -S "$CMUX_SOCKET_PATH" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$CMUX_PANEL_ID" ]] || return 0
    [[ -n "$_CMUX_TTY_NAME" ]] || return 0
    _CMUX_TTY_REPORTED=1
    {
        _cmux_send "report_tty $_CMUX_TTY_NAME --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
    } >/dev/null 2>&1 &
}

_cmux_ports_kick() {
    # Lightweight: just tell the app to run a batched scan for this panel.
    # The app coalesces kicks across all panels and runs a single ps+lsof.
    [[ -S "$CMUX_SOCKET_PATH" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$CMUX_PANEL_ID" ]] || return 0
    _CMUX_PORTS_LAST_RUN=$SECONDS
    {
        _cmux_send "ports_kick --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
    } >/dev/null 2>&1 &
}

_cmux_tmux_publish_pane_context() {
    [[ -n "${TMUX:-}" ]] || return 0
    [[ -n "${TMUX_PANE:-}" ]] || return 0
    [[ -S "$CMUX_SOCKET_PATH" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$CMUX_PANEL_ID" ]] || return 0
    command -v tmux >/dev/null 2>&1 || return 0

    local key="${TMUX_PANE}|${CMUX_TAB_ID}|${CMUX_PANEL_ID}|${CMUX_SOCKET_PATH}"
    [[ "$key" == "$_CMUX_TMUX_CONTEXT_KEY" ]] && return 0

    tmux set-option -p -t "$TMUX_PANE" @cmux_workspace_id "$CMUX_TAB_ID" >/dev/null 2>&1 || return 0
    tmux set-option -p -t "$TMUX_PANE" @cmux_surface_id "$CMUX_PANEL_ID" >/dev/null 2>&1 || return 0
    tmux set-option -p -t "$TMUX_PANE" @cmux_socket_path "$CMUX_SOCKET_PATH" >/dev/null 2>&1 || true
    _CMUX_TMUX_CONTEXT_KEY="$key"
}

_cmux_tmux_bridge_ensure() {
    [[ "${CMUX_TMUX_OSC_BRIDGE_DISABLED:-0}" != "1" ]] || return 0
    [[ -n "${TMUX:-}" ]] || return 0
    [[ -S "$CMUX_SOCKET_PATH" ]] || return 0
    command -v cmux >/dev/null 2>&1 || return 0

    local tmux_socket="${TMUX%%,*}"
    [[ -n "$tmux_socket" ]] || return 0

    local now=$SECONDS
    if (( now - _CMUX_TMUX_BRIDGE_LAST_RUN < 20 )) && [[ "$tmux_socket" == "$_CMUX_TMUX_BRIDGE_SOCKET" ]]; then
        return 0
    fi
    _CMUX_TMUX_BRIDGE_LAST_RUN=$now
    _CMUX_TMUX_BRIDGE_SOCKET="$tmux_socket"

    local -a bridge_args=(
        tmux-osc-bridge
        --ensure
        --tmux-socket "$tmux_socket"
    )
    if [[ "${CMUX_TMUX_OSC_BRIDGE_DEBUG:-0}" == "1" ]]; then
        local debug_path="${CMUX_TMUX_OSC_BRIDGE_DEBUG_LOG:-/tmp/cmux-tmux-osc-bridge.log}"
        bridge_args+=(--debug-log "$debug_path")
    fi

    _cmux_tmux_bridge_shell_log "ensure tmux_socket=$tmux_socket mode=inside_tmux"
    {
        cmux "${bridge_args[@]}"
    } >/dev/null 2>&1 &
}

_cmux_tmux_bridge_shell_log() {
    [[ "${CMUX_TMUX_OSC_BRIDGE_DEBUG:-0}" == "1" ]] || return 0
    local path="${CMUX_TMUX_OSC_BRIDGE_SHELL_DEBUG_LOG:-/tmp/cmux-tmux-osc-bridge-shell.log}"
    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
    printf '[%s] %s\n' "$timestamp" "$1" >> "$path" 2>/dev/null || true
}

_cmux_tmux_prepare_launch() {
    [[ "${CMUX_TMUX_OSC_BRIDGE_DISABLED:-0}" != "1" ]] || return 0
    [[ -z "${TMUX:-}" ]] || return 0
    [[ -S "$CMUX_SOCKET_PATH" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$CMUX_PANEL_ID" ]] || return 0
    command -v tmux >/dev/null 2>&1 || return 0
    command -v cmux >/dev/null 2>&1 || return 0

    local explicit_socket=""
    local socket_label=""
    local -a server_args=()
    local i=1
    while (( i <= $# )); do
        local arg="${!i}"
        case "$arg" in
            -S|--socket)
                (( i++ ))
                local value="${!i}"
                if [[ -n "$value" ]]; then
                    explicit_socket="$value"
                    server_args+=(-S "$value")
                fi
                ;;
            -L)
                (( i++ ))
                local value="${!i}"
                if [[ -n "$value" ]]; then
                    socket_label="$value"
                    server_args+=(-L "$value")
                fi
                ;;
        esac
        (( i++ ))
    done

    _cmux_tmux_bridge_shell_log "prepare_launch args=$* explicit_socket=${explicit_socket:-nil} label=${socket_label:-nil}"

    local socket_hint="$explicit_socket"
    if [[ -z "$socket_hint" ]]; then
        local uid
        uid="$(id -u 2>/dev/null || echo 0)"
        if [[ -n "$socket_label" ]]; then
            socket_hint="/tmp/tmux-$uid/$socket_label"
        else
            socket_hint="/tmp/tmux-$uid/default"
        fi
    fi

    local now=$SECONDS
    if (( now - _CMUX_TMUX_LAUNCH_LAST_RUN < 3 )) && [[ "$socket_hint" == "$_CMUX_TMUX_LAUNCH_SOCKET" ]]; then
        _cmux_tmux_bridge_shell_log "prepare_launch throttled socket_hint=$socket_hint"
        return 0
    fi
    _CMUX_TMUX_LAUNCH_LAST_RUN=$now
    _CMUX_TMUX_LAUNCH_SOCKET="$socket_hint"

    {
        local resolved_socket="$socket_hint"
        local attempt=0
        while (( attempt < 20 )); do
            if command tmux "${server_args[@]}" list-panes -a -F '#{pane_id}' >/dev/null 2>&1; then
                command tmux "${server_args[@]}" set-option -gq @cmux_workspace_id "$CMUX_TAB_ID" >/dev/null 2>&1 || true
                command tmux "${server_args[@]}" set-option -gq @cmux_surface_id "$CMUX_PANEL_ID" >/dev/null 2>&1 || true
                command tmux "${server_args[@]}" set-option -gq @cmux_socket_path "$CMUX_SOCKET_PATH" >/dev/null 2>&1 || true

                local discovered_socket
                discovered_socket="$(command tmux "${server_args[@]}" list-sessions -F '#{socket_path}' 2>/dev/null | head -n 1)"
                if [[ -n "$discovered_socket" ]]; then
                    resolved_socket="$discovered_socket"
                fi

                _cmux_tmux_bridge_shell_log "prepare_launch connected socket=$resolved_socket attempt=$attempt"
                local -a bridge_args=(
                    tmux-osc-bridge
                    --ensure
                    --tmux-socket "$resolved_socket"
                )
                if [[ "${CMUX_TMUX_OSC_BRIDGE_DEBUG:-0}" == "1" ]]; then
                    local debug_path="${CMUX_TMUX_OSC_BRIDGE_DEBUG_LOG:-/tmp/cmux-tmux-osc-bridge.log}"
                    bridge_args+=(--debug-log "$debug_path")
                fi
                _cmux_tmux_bridge_shell_log "prepare_launch ensure socket=$resolved_socket"
                cmux "${bridge_args[@]}" >/dev/null 2>&1 || true
                break
            fi
            (( attempt++ ))
            sleep 0.2
        done
        if (( attempt >= 20 )); then
            _cmux_tmux_bridge_shell_log "prepare_launch timeout socket_hint=$socket_hint"
        fi
    } >/dev/null 2>&1 &
}

_cmux_prompt_command() {
    [[ -S "$CMUX_SOCKET_PATH" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$CMUX_PANEL_ID" ]] || return 0

    local now=$SECONDS
    local pwd="$PWD"

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

    if [[ -n "$_CMUX_PR_JOB_PID" ]]; then
        if ! kill -0 "$_CMUX_PR_JOB_PID" 2>/dev/null; then
            _CMUX_PR_JOB_PID=""
            _CMUX_PR_JOB_STARTED_AT=0
        elif (( _CMUX_PR_JOB_STARTED_AT > 0 )) && (( now - _CMUX_PR_JOB_STARTED_AT >= _CMUX_ASYNC_JOB_TIMEOUT )); then
            _CMUX_PR_JOB_PID=""
            _CMUX_PR_JOB_STARTED_AT=0
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
    _cmux_tmux_publish_pane_context
    _cmux_tmux_bridge_ensure

    # CWD: keep the app in sync with the actual shell directory.
    if [[ "$pwd" != "$_CMUX_PWD_LAST_PWD" ]]; then
        _CMUX_PWD_LAST_PWD="$pwd"
        {
            local qpwd="${pwd//\"/\\\"}"
            _cmux_send "report_pwd \"${qpwd}\" --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
        } >/dev/null 2>&1 &
    fi

    # Git branch/dirty can change without a directory change (e.g. `git checkout`),
    # so update on every prompt (still async + de-duped by the running-job check).
    # When pwd changes (cd into a different repo), kill the old probe and start fresh
    # so the sidebar picks up the new branch immediately.
    if [[ -n "$_CMUX_GIT_JOB_PID" ]] && kill -0 "$_CMUX_GIT_JOB_PID" 2>/dev/null; then
        if [[ "$pwd" != "$_CMUX_GIT_LAST_PWD" ]]; then
            kill "$_CMUX_GIT_JOB_PID" >/dev/null 2>&1 || true
            _CMUX_GIT_JOB_PID=""
            _CMUX_GIT_JOB_STARTED_AT=0
        fi
    fi

    if [[ -z "$_CMUX_GIT_JOB_PID" ]] || ! kill -0 "$_CMUX_GIT_JOB_PID" 2>/dev/null; then
        _CMUX_GIT_LAST_PWD="$pwd"
        _CMUX_GIT_LAST_RUN=$now
        {
            local branch dirty_opt=""
            branch=$(git branch --show-current 2>/dev/null)
            if [[ -n "$branch" ]]; then
                local first
                first=$(git status --porcelain -uno 2>/dev/null | head -1)
                [[ -n "$first" ]] && dirty_opt="--status=dirty"
                _cmux_send "report_git_branch $branch $dirty_opt --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
            else
                _cmux_send "clear_git_branch --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
            fi
        } >/dev/null 2>&1 &
        _CMUX_GIT_JOB_PID=$!
        _CMUX_GIT_JOB_STARTED_AT=$now
    fi

    # Pull request metadata (number/state/url):
    # refresh on cwd change and periodically to avoid stale status.
    if [[ -n "$_CMUX_PR_JOB_PID" ]] && kill -0 "$_CMUX_PR_JOB_PID" 2>/dev/null; then
        if [[ "$pwd" != "$_CMUX_PR_LAST_PWD" ]]; then
            kill "$_CMUX_PR_JOB_PID" >/dev/null 2>&1 || true
            _CMUX_PR_JOB_PID=""
            _CMUX_PR_JOB_STARTED_AT=0
        fi
    fi

    if [[ "$pwd" != "$_CMUX_PR_LAST_PWD" ]] || (( now - _CMUX_PR_LAST_RUN >= 60 )); then
        if [[ -z "$_CMUX_PR_JOB_PID" ]] || ! kill -0 "$_CMUX_PR_JOB_PID" 2>/dev/null; then
            _CMUX_PR_LAST_PWD="$pwd"
            _CMUX_PR_LAST_RUN=$now
            {
                local branch pr_tsv number state url status_opt=""
                branch=$(git branch --show-current 2>/dev/null)
                if [[ -z "$branch" ]] || ! command -v gh >/dev/null 2>&1; then
                    _cmux_send "clear_pr --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
                else
                    pr_tsv="$(gh pr view --json number,state,url --jq '[.number, .state, .url] | @tsv' 2>/dev/null || true)"
                    if [[ -z "$pr_tsv" ]]; then
                        _cmux_send "clear_pr --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
                    else
                        IFS=$'\t' read -r number state url <<< "$pr_tsv"
                        if [[ -z "$number" || -z "$url" ]]; then
                            _cmux_send "clear_pr --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
                        else
                            case "$state" in
                                MERGED) status_opt="--state=merged" ;;
                                OPEN) status_opt="--state=open" ;;
                                CLOSED) status_opt="--state=closed" ;;
                                *) status_opt="" ;;
                            esac
                            _cmux_send "report_pr $number $url $status_opt --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
                        fi
                    fi
                fi
            } >/dev/null 2>&1 &
            _CMUX_PR_JOB_PID=$!
            _CMUX_PR_JOB_STARTED_AT=$now
        fi
    fi

    # Ports: lightweight kick to the app's batched scanner every ~10s.
    if (( now - _CMUX_PORTS_LAST_RUN >= 10 )); then
        _cmux_ports_kick
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
}

# Ensure Resources/bin is at the front of PATH, and remove the app's
# Contents/MacOS entry so the GUI cmux binary cannot shadow the CLI cmux.
# Shell init (.bashrc/.bash_profile) may prepend other dirs after launch.
_cmux_fix_path() {
    if [[ -n "${GHOSTTY_BIN_DIR:-}" ]]; then
        local gui_dir="${GHOSTTY_BIN_DIR%/}"
        local bin_dir="${gui_dir%/MacOS}/Resources/bin"
        if [[ -d "$bin_dir" ]]; then
            local new_path=":${PATH}:"
            new_path="${new_path//:${bin_dir}:/:}"
            new_path="${new_path//:${gui_dir}:/:}"
            new_path="${new_path#:}"
            new_path="${new_path%:}"
            PATH="${bin_dir}:${new_path}"
        fi
    fi
}
_cmux_fix_path
unset -f _cmux_fix_path

_cmux_install_prompt_command

tmux() {
    _cmux_tmux_prepare_launch "$@"
    command tmux "$@"
}

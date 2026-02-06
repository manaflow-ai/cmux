# cmuxterm shell integration for zsh
# Injected automatically — do not source manually

_cmux_send() {
    local payload="$1"
    if command -v ncat >/dev/null 2>&1; then
        print -r -- "$payload" | ncat -U "$CMUX_SOCKET_PATH" --send-only
    elif command -v socat >/dev/null 2>&1; then
        print -r -- "$payload" | socat - "UNIX-CONNECT:$CMUX_SOCKET_PATH"
    elif command -v nc >/dev/null 2>&1; then
        # Some nc builds don't support unix sockets, but keep as a last-ditch fallback.
        print -r -- "$payload" | nc -U "$CMUX_SOCKET_PATH"
    fi
}

# Throttle heavy work to avoid prompt latency.
typeset -g _CMUX_PWD_LAST_PWD=""
typeset -g _CMUX_GIT_LAST_PWD=""
typeset -g _CMUX_GIT_LAST_RUN=0
typeset -g _CMUX_GIT_JOB_PID=""
typeset -g _CMUX_GIT_FORCE=0

typeset -g _CMUX_PORTS_LAST_RUN=0
typeset -g _CMUX_PORTS_JOB_PID=""
typeset -g _CMUX_CMD_START=0
typeset -g _CMUX_TTY_NAME=""

_cmux_ports_scan() {
    [[ -n "$CMUX_PANEL_ID" ]] || return 0

    # Report listening TCP ports for the current shell session only (so a fresh
    # tab doesn't inherit unrelated machine-wide ports). We restrict the scan to
    # the current controlling TTY which keeps this cheap enough to run often.
    local -a ports
    local line name port

    # Best-effort: restrict to the current controlling TTY so a fresh tab doesn't
    # inherit unrelated machine-wide ports. This is a pragmatic heuristic that
    # works well for typical dev servers started from that shell.
    local tty_name pids_csv
    tty_name="$_CMUX_TTY_NAME"
    if [[ -z "$tty_name" ]]; then
        local t
        t="$(tty 2>/dev/null || true)"
        t="${t##*/}"
        [[ "$t" != "not a tty" ]] && tty_name="$t"
    fi

    if [[ -z "$tty_name" ]]; then
        _cmux_send "clear_ports --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
        return 0
    fi

    pids_csv="$(ps -axo pid=,tty= 2>/dev/null | awk -v tty="$tty_name" '$2 == tty {print $1}' | tr '\n' ',' || true)"
    pids_csv="${pids_csv%,}"
    if [[ -z "$pids_csv" ]]; then
        _cmux_send "clear_ports --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
        return 0
    fi

    while IFS= read -r line; do
        [[ "$line" == n* ]] || continue
        name="${line#n}"
        # Defensive: if the format ever includes a remote endpoint, keep the local side.
        name="${name%%->*}"
        port="${name##*:}"
        # Strip anything non-numeric (paranoia: "8000 (LISTEN)" etc).
        port="${port%%[^0-9]*}"
        [[ -n "$port" ]] && ports+=("$port")
    done < <(
        lsof -nP -a -p "$pids_csv" -iTCP -sTCP:LISTEN -F n 2>/dev/null || true
    )

    ports=("${(@u)ports}")
    ports=("${(@on)ports}")

    if (( ${#ports[@]} > 0 )); then
        _cmux_send "report_ports ${(j: :)ports} --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
    else
        _cmux_send "clear_ports --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
    fi
}

_cmux_ports_kick() {
    # De-duped, async scans (with a short burst) so we still update when a command
    # runs in the foreground (no prompt updates while it is running).
    [[ -S "$CMUX_SOCKET_PATH" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$CMUX_PANEL_ID" ]] || return 0
    if [[ -n "$_CMUX_PORTS_JOB_PID" ]] && kill -0 "$_CMUX_PORTS_JOB_PID" 2>/dev/null; then
        return 0
    fi
    _CMUX_PORTS_LAST_RUN=$EPOCHSECONDS
    {
        # Scan over ~10 seconds so slow-starting servers (e.g. `npm run dev`)
        # still show ports while the command is in the foreground.
        sleep 0.5 2>/dev/null || true
        _cmux_ports_scan
        sleep 1.0 2>/dev/null || true
        _cmux_ports_scan
        sleep 1.5 2>/dev/null || true
        _cmux_ports_scan
        sleep 2.0 2>/dev/null || true
        _cmux_ports_scan
        sleep 2.5 2>/dev/null || true
        _cmux_ports_scan
        sleep 2.5 2>/dev/null || true
        _cmux_ports_scan
    } >/dev/null 2>&1 &!
    _CMUX_PORTS_JOB_PID=$!
}

_cmux_preexec() {
    if [[ -z "$_CMUX_TTY_NAME" ]]; then
        local t
        t="$(tty 2>/dev/null || true)"
        t="${t##*/}"
        [[ -n "$t" && "$t" != "not a tty" ]] && _CMUX_TTY_NAME="$t"
    fi

    _CMUX_CMD_START=$EPOCHSECONDS

    # Heuristic: git commands can change branch/dirty state without changing $PWD.
    local cmd="${1## }"
    if [[ "$cmd" == git\ * || "$cmd" == git ]]; then
        _CMUX_GIT_FORCE=1
    fi

    # Ports can change due to long-running foreground commands (servers), so start
    # a short scan burst after command launch.
    _cmux_ports_kick
}

_cmux_precmd() {
    # Skip if socket doesn't exist yet
    [[ -S "$CMUX_SOCKET_PATH" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$CMUX_PANEL_ID" ]] || return 0

    if [[ -z "$_CMUX_TTY_NAME" ]]; then
        local t
        t="$(tty 2>/dev/null || true)"
        t="${t##*/}"
        [[ -n "$t" && "$t" != "not a tty" ]] && _CMUX_TTY_NAME="$t"
    fi

    local now=$EPOCHSECONDS
    local pwd="$PWD"
    local cmd_start="$_CMUX_CMD_START"
    _CMUX_CMD_START=0

    # CWD: keep the app in sync with the actual shell directory.
    # This is also the simplest way to test sidebar directory behavior end-to-end.
    if [[ "$pwd" != "$_CMUX_PWD_LAST_PWD" ]]; then
        _CMUX_PWD_LAST_PWD="$pwd"
        {
            # Quote to preserve spaces.
            local qpwd="${pwd//\"/\\\"}"
            _cmux_send "report_pwd \"${qpwd}\" --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
        } >/dev/null 2>&1 &!
    fi

    # Git branch/dirty: update immediately on directory change, otherwise every ~3s.
    local should_git=0
    if [[ "$pwd" != "$_CMUX_GIT_LAST_PWD" ]]; then
        should_git=1
    elif (( _CMUX_GIT_FORCE )); then
        should_git=1
    elif (( now - _CMUX_GIT_LAST_RUN >= 3 )); then
        should_git=1
    fi

    if (( should_git )); then
        if [[ -n "$_CMUX_GIT_JOB_PID" ]] && kill -0 "$_CMUX_GIT_JOB_PID" 2>/dev/null; then
            : # previous update still running
        else
            _CMUX_GIT_FORCE=0
            _CMUX_GIT_LAST_PWD="$pwd"
            _CMUX_GIT_LAST_RUN=$now
            {
                local branch dirty_opt=""
                branch=$(git branch --show-current 2>/dev/null)
                if [[ -n "$branch" ]]; then
                    local first
                    first=$(git status --porcelain -uno 2>/dev/null | head -1)
                    [[ -n "$first" ]] && dirty_opt="--status=dirty"
                    _cmux_send "report_git_branch $branch $dirty_opt --tab=$CMUX_TAB_ID"
                else
                    _cmux_send "clear_git_branch --tab=$CMUX_TAB_ID"
                fi
            } >/dev/null 2>&1 &!
            _CMUX_GIT_JOB_PID=$!
        fi
    fi

    # Ports:
    # - Periodic scan to avoid stale values.
    # - Forced scan when a long-running command returns to the prompt (common when stopping a server).
    local cmd_dur=0
    if [[ -n "$cmd_start" && "$cmd_start" != 0 ]]; then
        cmd_dur=$(( now - cmd_start ))
    fi

    if (( cmd_dur >= 2 || now - _CMUX_PORTS_LAST_RUN >= 10 )); then
        _cmux_ports_kick
    fi
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _cmux_preexec
add-zsh-hook precmd _cmux_precmd

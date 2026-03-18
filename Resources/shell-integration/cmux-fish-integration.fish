# cmux shell integration for fish
# Injected automatically — do not source manually

function _cmux_send
    set -l payload "$argv[1]"
    if command -q ncat
        printf '%s\n' "$payload" | ncat -w 1 -U "$CMUX_SOCKET_PATH" --send-only 2>/dev/null
    else if command -q socat
        printf '%s\n' "$payload" | socat -T 1 - "UNIX-CONNECT:$CMUX_SOCKET_PATH" 2>/dev/null
    else if command -q nc
        # Prefer flags that guarantee we exit after sending
        if printf '%s\n' "$payload" | nc -N -U "$CMUX_SOCKET_PATH" 2>/dev/null
            return 0
        else
            printf '%s\n' "$payload" | nc -w 1 -U "$CMUX_SOCKET_PATH" 2>/dev/null
        end
    end
end

function _cmux_restore_scrollback_once
    set -l path "$CMUX_RESTORE_SCROLLBACK_FILE"
    test -n "$path" || return 0
    set -e CMUX_RESTORE_SCROLLBACK_FILE

    if test -r "$path"
        /bin/cat -- "$path" 2>/dev/null || true
        /bin/rm -f -- "$path" 2>/dev/null || true
    end
end
_cmux_restore_scrollback_once

# State variables
set -g _cmux_pwd_last_pwd ""
set -g _cmux_ports_last_run 0
set -g _cmux_tty_name ""
set -g _cmux_tty_reported 0
set -g _cmux_shell_activity_last ""
set -g _cmux_cmd_start 0

function _cmux_report_tty_once
    test "$_cmux_tty_reported" = 1 && return 0
    test -S "$CMUX_SOCKET_PATH" || return 0
    test -n "$CMUX_TAB_ID" || return 0
    test -n "$CMUX_PANEL_ID" || return 0
    test -n "$_cmux_tty_name" || return 0

    set -g _cmux_tty_reported 1
    _cmux_send "report_tty $_cmux_tty_name --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID" &
end

function _cmux_report_shell_activity_state
    set -l state "$argv[1]"
    test -n "$state" || return 0
    test -S "$CMUX_SOCKET_PATH" || return 0
    test -n "$CMUX_TAB_ID" || return 0
    test -n "$CMUX_PANEL_ID" || return 0
    test "$_cmux_shell_activity_last" = "$state" && return 0

    set -g _cmux_shell_activity_last "$state"
    _cmux_send "report_shell_state $state --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID" &
end

function _cmux_ports_kick
    test -S "$CMUX_SOCKET_PATH" || return 0
    test -n "$CMUX_TAB_ID" || return 0
    test -n "$CMUX_PANEL_ID" || return 0

    set -g _cmux_ports_last_run (date +%s)
    _cmux_send "ports_kick --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID" &
end

function _cmux_preexec --on-event fish_preexec
    # Resolve TTY name once
    if test -z "$_cmux_tty_name"
        set -g _cmux_tty_name (tty 2>/dev/null | string replace -r '^.*/' '')
    end

    set -g _cmux_cmd_start (date +%s)
    _cmux_report_shell_activity_state running
    _cmux_report_tty_once
    _cmux_ports_kick
end

function _cmux_precmd --on-event fish_prompt
    test -S "$CMUX_SOCKET_PATH" || return 0
    test -n "$CMUX_TAB_ID" || return 0
    test -n "$CMUX_PANEL_ID" || return 0

    _cmux_report_shell_activity_state prompt

    # Resolve TTY name once
    if test -z "$_cmux_tty_name"
        set -g _cmux_tty_name (tty 2>/dev/null | string replace -r '^.*/' '')
    end

    _cmux_report_tty_once

    set -l now (date +%s)
    set -l pwd "$PWD"
    set -l cmd_start "$_cmux_cmd_start"
    set -g _cmux_cmd_start 0

    # CWD: keep the app in sync
    if test "$pwd" != "$_cmux_pwd_last_pwd"
        set -g _cmux_pwd_last_pwd "$pwd"
        set -l qpwd (string replace -a '"' '\\"' "$pwd")
        _cmux_send "report_pwd \"$qpwd\" --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID" &
    end

    # Ports: lightweight kick to the app's batched scanner
    # - Periodic scan to avoid stale values
    # - Forced scan when a long-running command returns
    set -l cmd_dur 0
    if test -n "$cmd_start" && test "$cmd_start" != 0
        set cmd_dur (math "$now - $cmd_start")
    end

    if test "$cmd_dur" -ge 2 2>/dev/null || test (math "$now - $_cmux_ports_last_run") -ge 10 2>/dev/null
        _cmux_ports_kick
    end
end

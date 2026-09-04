# cmux shell integration for nushell
# Sourced automatically by the cmux nushell bootstrap; do not source manually.
#
# Feature parity target is the fish integration
# (Resources/shell-integration/fish/config.fish): socket reporting of tty,
# shell activity state, pwd changes, and port-scan kicks, plus the claude/grok
# CLI wrappers, scrollback restore, and the keyboard-protocol reset. The
# zsh-only extras (git-branch probes, PR polling, Ghostty job-table patching)
# are intentionally not replicated here.
#
# State lives in _CMUX_* environment variables because nushell hook closures
# cannot mutate the environment; cmux registers string hooks that call the
# `def --env` entry points below, so mutations persist across prompts.

# Whether the cmux integration is active (CMUX_SHELL_INTEGRATION=0 disables it).
def _cmux_integration_enabled [] {
    ($env.CMUX_SHELL_INTEGRATION? | default "1") != "0"
}

# Picks the socket transport once at source time: ncat, socat, or nc.
def _cmux_pick_send_tool [] {
    if (which ncat | is-not-empty) {
        "ncat"
    } else if (which socat | is-not-empty) {
        "socat"
    } else if (which nc | is-not-empty) {
        "nc"
    } else {
        ""
    }
}

# Whether CMUX_SOCKET_PATH points at a live unix socket; positive results are
# cached for the session because the probe forks /bin/test.
def --env _cmux_socket_is_unix [] {
    let sock = ($env.CMUX_SOCKET_PATH? | default "")
    if ($sock | is-empty) { return false }
    if not ($sock | str starts-with "/") { return false }
    # The probe forks /bin/test and this runs from every prompt hook, so cache
    # the positive result for the session (the socket path is session-stable).
    # A negative result is not cached: the socket may come up moments later.
    if ($env._CMUX_SOCKET_IS_UNIX? | default "") == $"yes:($sock)" { return true }
    let live = ((^/bin/test -S $sock | complete | get exit_code) == 0)
    if $live { $env._CMUX_SOCKET_IS_UNIX = $"yes:($sock)" }
    $live
}

# Resolves the cmux CLI used for remote-relay RPCs, preferring the bundled binary.
def _cmux_relay_cli_path [] {
    let bundled = ($env.CMUX_BUNDLED_CLI_PATH? | default "")
    if ($bundled != "") and ($bundled | path exists) { return $bundled }
    which cmux | get -o 0.path | default ""
}

# Whether CMUX_SOCKET_PATH is a host:port relay address reachable through the cmux CLI.
def _cmux_socket_uses_remote_relay [] {
    let sock = ($env.CMUX_SOCKET_PATH? | default "")
    if ($sock | is-empty) { return false }
    if ($sock | str starts-with "/") { return false }
    if not ($sock | str contains ":") { return false }
    (_cmux_relay_cli_path) != ""
}

# Sends one payload line to the cmux socket, synchronously.
def _cmux_send [payload: string] {
    if ($payload | is-empty) { return }
    let sock = ($env.CMUX_SOCKET_PATH? | default "")
    if ($sock | is-empty) { return }
    let tool = ($env._CMUX_SEND_TOOL? | default "")
    let line = $"($payload)(char nl)"
    if $tool == "ncat" {
        $line | ^ncat -w 1 -U $sock --send-only | complete | ignore
    } else if $tool == "socat" {
        $line | ^socat -T 1 - $"UNIX-CONNECT:($sock)" | complete | ignore
    } else if $tool == "nc" {
        let first = ($line | ^nc -N -U $sock | complete)
        if $first.exit_code != 0 {
            $line | ^nc -w 1 -U $sock | complete | ignore
        }
    }
}

# Sends a payload without blocking the prompt (job spawn). CMUX_TEST_SYNC_SEND=1
# forces the synchronous path so tests are deterministic (nushell kills jobs at
# shell exit, which a -c script would race).
def _cmux_send_bg [payload: string] {
    if ($env.CMUX_TEST_SYNC_SEND? | default "") == "1" {
        _cmux_send $payload
        return
    }
    job spawn { _cmux_send $payload } | ignore
}

# Escapes a value for the quoted field of a socket payload, mirroring the fish
# integration's escaping so the app-side parser sees identical wire format.
def _cmux_json_escape [value: string] {
    $value
    | str replace -a "\\" "\\\\"
    | str replace -a '"' '\"'
    | str replace -a "\n" "\\n"
    | str replace -a "\r" "\\r"
    | str replace -a "\t" "\\t"
}

# Workspace id for relay RPC params, falling back to the tab id.
def _cmux_relay_workspace_id [] {
    let workspace = ($env.CMUX_WORKSPACE_ID? | default "")
    if $workspace != "" { return $workspace }
    $env.CMUX_TAB_ID? | default ""
}

# Fires a cmux relay RPC without blocking the prompt.
def _cmux_relay_rpc_bg [method: string, params: string] {
    let cli = (_cmux_relay_cli_path)
    if ($cli | is-empty) { return }
    if ($env.CMUX_TEST_SYNC_SEND? | default "") == "1" {
        ^$cli rpc $method $params | complete | ignore
        return
    }
    job spawn { ^$cli rpc $method $params | complete | ignore } | ignore
}

# Reports the tty name through the remote relay.
def _cmux_report_tty_via_relay [] {
    if not (_cmux_socket_uses_remote_relay) { return }
    let name = ($env._CMUX_TTY_NAME? | default "")
    if ($name | is-empty) { return }
    let workspace = (_cmux_relay_workspace_id)
    if ($workspace | is-empty) { return }
    mut payload = {workspace_id: $workspace, tty_name: $name}
    let panel = ($env.CMUX_PANEL_ID? | default "")
    if $panel != "" { $payload = ($payload | insert surface_id $panel) }
    _cmux_relay_rpc_bg surface.report_tty ($payload | to json --raw)
}

# Reports a cwd change through the remote relay; returns true when dispatched.
def _cmux_report_pwd_via_relay [pwd: string] {
    if not (_cmux_socket_uses_remote_relay) { return false }
    if ($pwd | is-empty) { return false }
    let workspace = (_cmux_relay_workspace_id)
    if ($workspace | is-empty) { return false }
    mut payload = {workspace_id: $workspace, path: $pwd}
    let panel = ($env.CMUX_PANEL_ID? | default "")
    if $panel != "" { $payload = ($payload | insert surface_id $panel) }
    _cmux_relay_rpc_bg surface.report_pwd ($payload | to json --raw)
    true
}

# Requests a port scan through the remote relay.
def _cmux_ports_kick_via_relay [reason: string] {
    if not (_cmux_socket_uses_remote_relay) { return }
    let workspace = (_cmux_relay_workspace_id)
    if ($workspace | is-empty) { return }
    mut payload = {workspace_id: $workspace, reason: $reason}
    let panel = ($env.CMUX_PANEL_ID? | default "")
    if $panel != "" { $payload = ($payload | insert surface_id $panel) }
    _cmux_relay_rpc_bg surface.ports_kick ($payload | to json --raw)
}

# Reports the surface tty once per session so cmux can map this shell to its
# panel. Honors a preset _CMUX_TTY_NAME (tests have no tty to probe).
def --env _cmux_report_tty_once [] {
    if ($env._CMUX_TTY_REPORTED? | default "") == "1" { return }
    mut name = ($env._CMUX_TTY_NAME? | default "")
    if ($name | is-empty) {
        let probe = (^tty | complete)
        if $probe.exit_code == 0 {
            $name = ($probe.stdout | str trim | str replace -r '^.*/' '')
        }
    }
    if ($name | is-empty) or ($name == "not a tty") { return }
    $env._CMUX_TTY_NAME = $name
    if (_cmux_socket_is_unix) {
        let tab = ($env.CMUX_TAB_ID? | default "")
        if ($tab | is-empty) { return }
        let panel = ($env.CMUX_PANEL_ID? | default "")
        if ($panel | is-empty) { return }
        $env._CMUX_TTY_REPORTED = "1"
        _cmux_send_bg $"report_tty ($name) --tab=($tab) --panel=($panel)"
    } else if (_cmux_socket_uses_remote_relay) {
        $env._CMUX_TTY_REPORTED = "1"
        _cmux_report_tty_via_relay
    }
}

# Reports busy/idle transitions (running/prompt), deduped across repeated prompts.
def --env _cmux_report_shell_activity_state [state: string] {
    if ($state | is-empty) { return }
    # Dedupe before the socket probe: this runs on every prompt and the
    # state is unchanged almost every time.
    if ($env._CMUX_SHELL_ACTIVITY_LAST? | default "") == $state { return }
    if not (_cmux_socket_is_unix) { return }
    let tab = ($env.CMUX_TAB_ID? | default "")
    if ($tab | is-empty) { return }
    let panel = ($env.CMUX_PANEL_ID? | default "")
    if ($panel | is-empty) { return }
    $env._CMUX_SHELL_ACTIVITY_LAST = $state
    _cmux_send_bg $"report_shell_state ($state) --tab=($tab) --panel=($panel)"
}

# Reports the cwd when it changed since the last prompt; feeds cmux's
# workspace current-directory tracking.
def --env _cmux_report_pwd_if_changed [] {
    let pwd = $env.PWD
    if $pwd == ($env._CMUX_PWD_LAST_PWD? | default "") { return }
    if (_cmux_socket_is_unix) {
        let tab = ($env.CMUX_TAB_ID? | default "")
        if ($tab | is-empty) { return }
        let panel = ($env.CMUX_PANEL_ID? | default "")
        if ($panel | is-empty) { return }
        let qpwd = (_cmux_json_escape $pwd)
        _cmux_send_bg $"report_pwd \"($qpwd)\" --tab=($tab) --panel=($panel)"
        $env._CMUX_PWD_LAST_PWD = $pwd
    } else if (_cmux_report_pwd_via_relay $pwd) {
        $env._CMUX_PWD_LAST_PWD = $pwd
    }
}

# Requests a cmux port scan (reason: command or refresh).
def --env _cmux_ports_kick [reason: string] {
    mut why = $reason
    if ($why | is-empty) { $why = "command" }
    let tab = ($env.CMUX_TAB_ID? | default "")
    if ($tab | is-empty) { return }
    $env._CMUX_PORTS_LAST_RUN = (date now | format date "%s")
    if (_cmux_socket_is_unix) {
        let panel = ($env.CMUX_PANEL_ID? | default "")
        if ($panel | is-empty) { return }
        _cmux_send_bg $"ports_kick --tab=($tab) --panel=($panel) --reason=($why)"
    } else {
        _cmux_ports_kick_via_relay $why
    }
}

# Resets modifyOtherKeys/kitty keyboard protocols a crashed TUI can leave enabled.
def _cmux_reset_terminal_keyboard_protocols [] {
    let forced = ($env.CMUX_TEST_FORCE_KEYBOARD_RESET? | default "") + ($env.CMUX_TEST_FORCE_KITTY_RESET? | default "")
    if ($forced | is-empty) and not (is-terminal --stdout) { return }
    print -n "\e[>m\e[<8u"
}

# Replays saved scrollback into a restored surface, bracketed by the OSC 1337
# markers cmux recognizes, then deletes the replay file.
def --env _cmux_restore_scrollback_once [] {
    let path = ($env.CMUX_RESTORE_SCROLLBACK_FILE? | default "")
    if ($path | is-empty) { return }
    hide-env CMUX_RESTORE_SCROLLBACK_FILE
    let token = ($path | str replace -r '^.*/' '')
    let host = (^/bin/hostname | complete | get stdout | str trim)
    print -n $"\e]1337;CurrentDir=kitty-shell-cwd://($host)/.cmux/session-scrollback-replay/($token)/start\u{07}"
    if ($path | path exists) {
        try { ^/bin/cat -- $path }
        ^/bin/rm -f -- $path | complete | ignore
    }
    print -n $"\e]1337;CurrentDir=kitty-shell-cwd://($host)/.cmux/session-scrollback-replay/($token)/end\u{07}"
    print -n $"\e]1337;CurrentDir=kitty-shell-cwd://($host)($env.PWD)\u{07}"
}

# Locates a bundled cmux CLI wrapper relative to CMUX_SHELL_INTEGRATION_DIR.
def _cmux_wrapper_path [wrapper_file: string] {
    let dir = ($env.CMUX_SHELL_INTEGRATION_DIR? | default "")
    if ($dir | is-empty) { return "" }
    let bundle = ($dir | str replace -r '/shell-integration/?$' '')
    let candidate = ($bundle | path join "bin" $wrapper_file)
    if ($candidate | path exists) { $candidate } else { "" }
}

# Route `claude` through the cmux wrapper so session tracking and
# notification hooks are injected even if later PATH edits shadow the
# per-surface shim. `^claude` resolves the real external through PATH.
def --wrapped claude [...args: string] {
    let shim = ($env.CMUX_CLAUDE_WRAPPER_SHIM? | default "")
    if ($shim != "") and ($shim | path exists) {
        ^$shim ...$args
    } else {
        let wrapper = (_cmux_wrapper_path "cmux-claude-wrapper")
        if ($wrapper != "") {
            ^$wrapper ...$args
        } else {
            ^claude ...$args
        }
    }
}

# Routes grok through the bundled cmux wrapper when present.
def --wrapped grok [...args: string] {
    let wrapper = (_cmux_wrapper_path "grok")
    if ($wrapper != "") {
        ^$wrapper ...$args
    } else {
        ^grok ...$args
    }
}

# pre_execution hook: report tty + busy state and kick a port scan before a
# command runs.
def --env _cmux_pre_execution [] {
    if not (_cmux_integration_enabled) { return }
    _cmux_report_tty_once
    _cmux_report_shell_activity_state running
    _cmux_ports_kick command
}

# pre_prompt hook: keyboard reset, tty/idle/cwd reports, and a port-scan
# refresh at most every 5 seconds.
def --env _cmux_pre_prompt [] {
    if not (_cmux_integration_enabled) { return }
    _cmux_reset_terminal_keyboard_protocols
    _cmux_report_tty_once
    _cmux_report_shell_activity_state prompt
    _cmux_report_pwd_if_changed
    let now = (date now | format date "%s" | into int)
    let last = (($env._CMUX_PORTS_LAST_RUN? | default "0") | into int)
    if ($now - $last) >= 5 { _cmux_ports_kick refresh }
}

if (_cmux_integration_enabled) {
    $env._CMUX_SEND_TOOL = (_cmux_pick_send_tool)
    _cmux_restore_scrollback_once
    # String hooks (not closures) so the def --env entry points can persist
    # their dedupe state into the REPL environment.
    $env.config = ($env.config | upsert hooks.pre_execution (
        ($env.config.hooks.pre_execution? | default []) | append "_cmux_pre_execution"
    ))
    $env.config = ($env.config | upsert hooks.pre_prompt (
        ($env.config.hooks.pre_prompt? | default []) | append "_cmux_pre_prompt"
    ))
}

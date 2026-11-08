import Darwin
import Foundation

enum WorkspaceInitialCommandLoginShell {
    /// Resolves the user's login shell and wraps an externally supplied workspace command.
    ///
    /// Ghostty otherwise launches string commands through Bash with `--noprofile --norc`,
    /// so the user's profile cannot contribute tools such as Homebrew-installed agents.
    /// Ghostty prepends `exec -l`, so the returned command starts with the quoted shell path.
    static func wrap(_ command: String) -> String {
        let databaseShell: String?
        if let record = getpwuid(getuid()),
           let shell = record.pointee.pw_shell {
            let copiedShell = String(cString: shell)
            databaseShell = copiedShell.isEmpty ? nil : copiedShell
        } else {
            databaseShell = nil
        }

        let userShell = databaseShell
            ?? ProcessInfo.processInfo.environment["SHELL"]
            ?? "/bin/zsh"
        return wrap(command, userShell: userShell)
    }

    /// Wraps a command in a supported login shell while preserving the command verbatim.
    ///
    /// Login profiles can prepend other tool directories (Homebrew's `shellenv` puts
    /// `/opt/homebrew/bin` first) ahead of the per-surface shim directory that cmux
    /// seeds into the spawned PATH, which would route `claude`/`codex` around cmux's
    /// wrapper hooks. The payload therefore re-prepends the shim directory after
    /// profiles run; a duplicate PATH entry is harmless and matches what interactive
    /// shell integration already produces. The directory can sit in a shared
    /// temporary directory, so both the root and its ancestors are checked before
    /// any PATH change. The shared agent root also supports Claude-disabled panes.
    static func wrap(_ command: String, userShell: String?) -> String {
        var shellPath: String
        if let userShell, userShell.hasPrefix("/") {
            shellPath = userShell
        } else {
            shellPath = "/bin/zsh"
        }
        let payload: String
        let check = shellSingleQuoted(shimRootCheck)

        switch (shellPath as NSString).lastPathComponent {
        case "fish":
            payload = """
            set -l _cmux_previous_shim ""
            for _cmux_candidate_shim in "$CMUX_CLAUDE_WRAPPER_SHIM_ROOT" "$CMUX_AGENT_COMMAND_SHIM_ROOT"
                if test -n "$_cmux_candidate_shim"; and test "$_cmux_candidate_shim" != "$_cmux_previous_shim"; and /bin/sh -c \(check) cmux "$_cmux_candidate_shim"
                    set -gx PATH "$_cmux_candidate_shim" $PATH
                    set _cmux_previous_shim "$_cmux_candidate_shim"
                end
            end
            set -e _cmux_previous_shim _cmux_candidate_shim
            \(command)
            """
        case "zsh", "bash", "sh", "ksh", "dash":
            payload = """
            \(posixShimRootPrepend)
            \(command)
            """
        default:
            shellPath = "/bin/zsh"
            payload = """
            \(posixShimRootPrepend)
            \(command)
            """
        }

        return "\(shellSingleQuoted(shellPath)) -lc \(shellSingleQuoted(payload))"
    }

    private static var posixShimRootPrepend: String {
        """
        _cmux_previous_shim=''
        for _cmux_candidate_shim in "${CMUX_CLAUDE_WRAPPER_SHIM_ROOT:-}" "${CMUX_AGENT_COMMAND_SHIM_ROOT:-}"; do
            if [ -n "$_cmux_candidate_shim" ] && [ "$_cmux_candidate_shim" != "$_cmux_previous_shim" ] && /bin/sh -c \(shellSingleQuoted(shimRootCheck)) cmux "$_cmux_candidate_shim"; then
                PATH="$_cmux_candidate_shim${PATH:+:$PATH}"; export PATH
                _cmux_previous_shim=$_cmux_candidate_shim
            fi
        done
        unset _cmux_previous_shim _cmux_candidate_shim
        """
    }

    /// The same fixed POSIX predicate runs from every supported login shell;
    /// the candidate is argv data and never interpolated into executable code.
    private static let shimRootCheck = #"""
    _cmux_root=$1
    case "$_cmux_root" in /*) ;; *) exit 1 ;; esac
    while [ "$_cmux_root" != / ] && [ "${_cmux_root%/}" != "$_cmux_root" ]; do _cmux_root=${_cmux_root%/}; done
    [ -d "$_cmux_root" ] && [ ! -L "$_cmux_root" ] || exit 1
    _cmux_uid=$(/usr/bin/id -u) || exit 1
    _cmux_meta() {
        _cmux_info=$(/usr/bin/stat -f '%HT:%u:%Mp%Lp' -- "$1" 2>/dev/null) || _cmux_info=$(/usr/bin/stat -c '%F:%u:%a' -- "$1" 2>/dev/null) || return 1
        _cmux_kind=${_cmux_info%%:*}
        _cmux_info=${_cmux_info#*:}
        _cmux_owner=${_cmux_info%%:*}
        _cmux_mode=${_cmux_info#*:}
        case "$_cmux_mode" in ''|*[!0-7]*) return 1 ;; esac
        _cmux_mode=$((0$_cmux_mode))
    }
    _cmux_chain_safe() {
        _cmux_current=$1
        while :; do
            _cmux_meta "$_cmux_current" || return 1
            [ "$_cmux_owner" = "$_cmux_uid" ] || [ "$_cmux_owner" = 0 ] || return 1
            case "$_cmux_kind" in
                Directory|directory) [ $((_cmux_mode & 0022)) -eq 0 ] || [ $((_cmux_mode & 01000)) -ne 0 ] || return 1 ;;
                'Symbolic Link'|'symbolic link') ;;
                *) return 1 ;;
            esac
            [ "$_cmux_current" = / ] && return 0
            _cmux_current=${_cmux_current%/*}
            [ -n "$_cmux_current" ] || _cmux_current=/
        done
    }
    _cmux_meta "$_cmux_root" || exit 1
    [ "$_cmux_owner" = "$_cmux_uid" ] && [ $((_cmux_mode & 0022)) -eq 0 ] || exit 1
    _cmux_chain_safe "$_cmux_root" || exit 1
    _cmux_resolved=$(CDPATH='' command cd -P "$_cmux_root" >/dev/null && /bin/pwd -P) || exit 1
    _cmux_chain_safe "$_cmux_resolved"
    """#

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

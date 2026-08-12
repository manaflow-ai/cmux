import Darwin
import Foundation

enum WorkspaceInitialCommandLoginShell {
    /// Resolves the user's login shell and wraps an externally supplied workspace command.
    ///
    /// Ghostty otherwise launches string commands through Bash with `--noprofile --norc`,
    /// so the user's profile cannot contribute tools such as Homebrew-installed agents.
    /// Ghostty prepends `exec -l`, so the returned command starts with the quoted shell path.
    static func wrap(_ command: String) -> String {
        wrap(command, userShell: resolvedUserShell())
    }

    /// The user's login shell, from the account record with the environment and
    /// zsh as fallbacks.
    static func resolvedUserShell() -> String {
        let databaseShell: String?
        if let record = getpwuid(getuid()),
           let shell = record.pointee.pw_shell {
            let copiedShell = String(cString: shell)
            databaseShell = copiedShell.isEmpty ? nil : copiedShell
        } else {
            databaseShell = nil
        }

        return databaseShell
            ?? ProcessInfo.processInfo.environment["SHELL"]
            ?? "/bin/zsh"
    }

    /// Wraps a command in an *interactive* login shell.
    ///
    /// Values such as `$EDITOR` are commonly exported from interactive-only
    /// configuration (`.zshrc`), which a plain login shell never reads.
    static func wrapInteractive(_ command: String, userShell: String?) -> String {
        wrap(command, userShell: userShell, interactive: true)
    }

    /// Wraps a command in a supported login shell while preserving the command verbatim.
    ///
    /// Login profiles can prepend other tool directories (Homebrew's `shellenv` puts
    /// `/opt/homebrew/bin` first) ahead of the per-surface shim directory that cmux
    /// seeds into the spawned PATH, which would route `claude`/`codex` around cmux's
    /// wrapper hooks. The payload therefore re-prepends the shim directory
    /// unconditionally after profiles run; a duplicate PATH entry is harmless and
    /// matches what interactive shell integration already produces.
    static func wrap(_ command: String, userShell: String?) -> String {
        wrap(command, userShell: userShell, interactive: false)
    }

    private static func wrap(
        _ command: String,
        userShell: String?,
        interactive: Bool
    ) -> String {
        var shellPath: String
        if let userShell, userShell.hasPrefix("/") {
            shellPath = userShell
        } else {
            shellPath = "/bin/zsh"
        }
        let payload: String

        switch (shellPath as NSString).lastPathComponent {
        case "fish":
            payload = """
            if test -n "$CMUX_CLAUDE_WRAPPER_SHIM_ROOT"; and test -d "$CMUX_CLAUDE_WRAPPER_SHIM_ROOT"; set -gx PATH "$CMUX_CLAUDE_WRAPPER_SHIM_ROOT" $PATH; end
            \(command)
            """
        case "zsh", "bash", "sh", "ksh", "dash":
            payload = """
            if [ -n "${CMUX_CLAUDE_WRAPPER_SHIM_ROOT:-}" ] && [ -d "${CMUX_CLAUDE_WRAPPER_SHIM_ROOT}" ]; then PATH="${CMUX_CLAUDE_WRAPPER_SHIM_ROOT}${PATH:+:$PATH}"; export PATH; fi
            \(command)
            """
        default:
            shellPath = "/bin/zsh"
            payload = """
            if [ -n "${CMUX_CLAUDE_WRAPPER_SHIM_ROOT:-}" ] && [ -d "${CMUX_CLAUDE_WRAPPER_SHIM_ROOT}" ]; then PATH="${CMUX_CLAUDE_WRAPPER_SHIM_ROOT}${PATH:+:$PATH}"; export PATH; fi
            \(command)
            """
        }

        let flags = interactive ? "-ilc" : "-lc"
        return "\(shellSingleQuoted(shellPath)) \(flags) \(shellSingleQuoted(payload))"
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

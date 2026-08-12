import Foundation

/// Renders cmux-generated POSIX one-liners for shells that cannot parse
/// POSIX syntax.
///
/// cmux builds resume/relaunch commands as POSIX strings (AND-OR lists,
/// `[ … ]` tests, single-quote escaping, `"$(printf …)"` substitutions) and
/// either types them into the user's interactive shell or dispatches them via
/// `"$SHELL" -c`. Nushell parses none of that: `&&`/`||` are dedicated parse
/// errors, `[ … ]` is a list literal, POSIX `'…'\''…'` concatenation does not
/// exist, and even a quoted command head (`'claude' …`) is rejected. Instead
/// of teaching every command builder a second dialect, the POSIX body is kept
/// as-is and delegated through `/bin/sh` at the final typed/dispatched
/// boundary — the same portable-envelope approach as
/// ``AgentResumeArgv/portableClaudeResumeShellCommand(posixCommand:)``
/// (issue #5639) and the `/bin/zsh <launcher-script>` startup inputs.
nonisolated public struct NushellTypedShellCommand: Sendable {
    /// The renderer is stateless; construct at the call site.
    public init() {}

    /// A nushell-parseable line that runs `posixCommand` through `/bin/sh`.
    ///
    /// `^` forces external-command resolution for the absolute-path head and
    /// the body rides in a nushell double-quoted string (no interpolation;
    /// only `\` and `"` need escaping). Verified against real nu by
    /// `tests/test_nushell_resume_command_dialect.py`.
    public func wrapping(posixCommand: String) -> String {
        "^/bin/sh -c " + doubleQuoted(posixCommand)
    }

    /// Double-quotes a value for generated nushell source. Nushell
    /// single-quoted strings cannot contain single quotes at all, so double
    /// quotes are the safe general form; escaping every backslash first
    /// guarantees no invalid escape sequence remains.
    public func doubleQuoted(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }
}

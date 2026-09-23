import Foundation

/// One localized explanation of why cmux did not resume an agent session in a
/// restored terminal.
///
/// Local panes show ``message`` as terminal display output through
/// `TerminalSurface.writeDisplayNotice(_:)`, so the shell never sees it.
/// ``startupInput(dialect:)`` exists only for the persistent-SSH fallback,
/// where the notice must print on the remote host after a lost PTY session is
/// replaced by a new remote shell.
struct AgentRestoreNoticeInput: Sendable {
    let message: String

    /// Renders the notice as a remote shell command. The message stays one
    /// single-quoted argument, so spaces and non-ASCII text survive intact.
    func startupInput(dialect: TerminalStartupShellDialect) -> String {
        let command = "/usr/bin/printf '%s\\n' " +
            TerminalStartupShellQuoting.singleQuoted(message)
        return " " + TerminalStartupTypedShellCommand(dialect: dialect)
            .typedInput(posixCommand: command) + "\n"
    }
}

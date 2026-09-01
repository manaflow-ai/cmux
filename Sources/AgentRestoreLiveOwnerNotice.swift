import Foundation

/// Renders the terminal-visible explanation for a suppressed duplicate restore.
struct AgentRestoreLiveOwnerNotice: Sendable {
    let processID: Int

    func startupInput(dialect: TerminalStartupShellDialect) -> String {
        let format = String(
            localized: "agentRestore.liveOwner.notice",
            defaultValue: "This agent session is already running in process %1$lld. cmux did not start another copy. To take it over here, stop process %1$lld, then run 'cmux restore --surface' again."
        )
        let message = String(
            format: format,
            locale: Locale.current,
            Int64(processID)
        )
        return startupInput(message: message, dialect: dialect)
    }

    /// Renders an already-localized message for shell-boundary tests.
    func startupInput(
        message: String,
        dialect: TerminalStartupShellDialect
    ) -> String {
        let command = "/usr/bin/printf '%s\\n' " +
            TerminalStartupShellQuoting.singleQuoted(message)
        return " " + TerminalStartupTypedShellCommand(dialect: dialect)
            .typedInput(posixCommand: command) + "\n"
    }
}

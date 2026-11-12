import Foundation

/// Renders the terminal-visible explanation when automatic resume was skipped
/// because the live-agent scan could not prove whether the session was
/// already running.
///
/// A bare shell prompt gives the user nothing to act on; this notice names the
/// cause and the manual recovery command (#12158).
struct AgentRestoreUnverifiableNotice: Sendable {
    func startupInput(dialect: TerminalStartupShellDialect) -> String {
        AgentRestoreNoticeInput(
            message: String(
                localized: "agentRestore.unverifiable.notice",
                defaultValue: "cmux could not verify whether this agent session is already running, so it did not resume the session automatically. Run 'cmux restore --surface' to resume it here."
            )
        ).startupInput(dialect: dialect)
    }
}

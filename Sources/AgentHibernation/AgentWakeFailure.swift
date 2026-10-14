import Foundation

/// Why a woken agent was judged not to have come back.
enum AgentWakeFailureReason: Equatable, Sendable {
    /// The resume command ran and returned to the shell prompt before the
    /// agent reported in.
    case exitedBeforeStart
    /// Nothing reported in before the verification deadline, and no live
    /// agent process was found for the pane.
    case didNotStart

    /// The second line of the failure banner and the feed entry body.
    var detail: String {
        switch self {
        case .exitedBeforeStart:
            String(
                localized: "agentWake.reason.exitedBeforeStart",
                defaultValue: "Its resume command exited."
            )
        case .didNotStart:
            String(
                localized: "agentWake.reason.didNotStart",
                defaultValue: "It did not start within 90 seconds."
            )
        }
    }
}

/// A failed wake shown on the terminal pane until retried, dismissed, or
/// superseded by a later success signal.
struct AgentWakeFailure {
    let reason: AgentWakeFailureReason
    /// The agent name shown to the user, for example "Claude Code".
    let agentDisplayName: String
    /// The command shown by "Show command". This is the agent's resume
    /// command when one exists, otherwise the typed startup input.
    let commandText: String
    let agent: SessionRestorableAgentSnapshot
    /// False while something still runs in the pane, where typing the resume
    /// command again would feed it to that program instead of the shell.
    var canRetry: Bool = true
}

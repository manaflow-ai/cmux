import Foundation

/// Why a woken agent was judged not to have come back.
enum AgentWakeFailureReason: Equatable, Sendable {
    /// The resume command ran and returned to the shell prompt before the
    /// agent reported in.
    case exitedBeforeStart
    /// Nothing reported in before the verification deadline, and no live
    /// agent process was found for the pane.
    case didNotStart
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
}

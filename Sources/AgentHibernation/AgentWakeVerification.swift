import Foundation

/// One pane's wake check, owned by its `Workspace`.
struct AgentWakeVerification {
    /// Identifies this check so a deadline scheduled for an older check does
    /// not act on a newer one.
    let token: UUID
    let agent: SessionRestorableAgentSnapshot
    let startedAt: Date
    /// The command shown to the user if the wake fails.
    let commandText: String
    var state: AgentWakeVerificationState
    var deadlineTask: Task<Void, Never>?
}

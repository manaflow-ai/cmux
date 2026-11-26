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

    /// Whether a hook report under `statusKey` comes from the woken agent.
    /// Hook status keys name the agent kind (Claude reports as
    /// `claude_code`); a Feed attention overlay for that agent counts too.
    /// Reports from another agent in the same pane leave the check pending.
    func acceptsReport(statusKey: String) -> Bool {
        let source = agent.kind.rawValue
        return statusKey == FeedCoordinator.lifecycleStatusKey(forSource: source)
            || statusKey == FeedCoordinator.attentionStatusKey(forSource: source)
    }
}

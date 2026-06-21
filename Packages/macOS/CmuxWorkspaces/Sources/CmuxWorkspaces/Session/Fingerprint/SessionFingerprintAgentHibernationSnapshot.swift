/// The agent-hibernation fields the session autosave fingerprint folds into its
/// hash, flattened off the app-target `AgentHibernationPanelState`.
///
/// Carries only the values the legacy
/// `TabManager.hashAgentHibernationPanelState(_:into:)` combined, in order: the
/// hibernated agent snapshot, then `hibernatedAt` and `lastActivityAt` already
/// reduced to `timeIntervalSince1970` Doubles by the app-side
/// ``SessionFingerprintHosting`` witness.
public struct SessionFingerprintAgentHibernationSnapshot: Sendable, Equatable {
    /// Legacy `AgentHibernationPanelState.agent`, flattened.
    public let agent: SessionFingerprintRestorableAgentSnapshot?
    /// Legacy `AgentHibernationPanelState.hibernatedAt.timeIntervalSince1970`.
    public let hibernatedAt: Double
    /// Legacy `AgentHibernationPanelState.lastActivityAt.timeIntervalSince1970`.
    public let lastActivityAt: Double

    /// Creates a flattened agent-hibernation fingerprint input.
    public init(
        agent: SessionFingerprintRestorableAgentSnapshot?,
        hibernatedAt: Double,
        lastActivityAt: Double
    ) {
        self.agent = agent
        self.hibernatedAt = hibernatedAt
        self.lastActivityAt = lastActivityAt
    }
}

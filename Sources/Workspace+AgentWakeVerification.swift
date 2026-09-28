import Foundation

extension Workspace {
    static let agentWakeFailedStatusKey = "agent.wakeFailed"
    static let agentWakeVerificationSeconds: TimeInterval = 90

    // Stub: records nothing yet.
    func beginAgentWakeVerification(panelId: UUID, agent: SessionRestorableAgentSnapshot) {}

    // Stub: reports nothing yet.
    func failAgentWakeVerification(panelId: UUID, reason: AgentWakeFailureReason) {}

    // Stub: dismisses nothing yet.
    func dismissAgentWakeFailure(panelId: UUID) {}
}

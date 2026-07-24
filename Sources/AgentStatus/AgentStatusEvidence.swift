import CmuxWorkspaces
import Foundation

/// Timestamped observations used to derive one agent's status on one panel.
struct AgentStatusEvidence: Equatable, Sendable {
    var lifecycle: AgentHibernationLifecycleState?
    var lifecycleObservedAt: Date?
    var lifecycleRuntimePIDKey: String?
    var lifecycleRuntimeProcessIdentity: AgentPIDProcessIdentity?
    var lifecycleRevision: UInt64?
    var outputObservedAt: Date?
    var titleObservedAt: Date?
    var foregroundAgentStatusKey: String?
    var foregroundObservedAt: Date?
    var shellActivity: PanelShellActivityState
    var shellActivityObservedAt: Date?

    init(
        lifecycle: AgentHibernationLifecycleState? = nil,
        lifecycleObservedAt: Date? = nil,
        lifecycleRuntimePIDKey: String? = nil,
        lifecycleRuntimeProcessIdentity: AgentPIDProcessIdentity? = nil,
        lifecycleRevision: UInt64? = nil,
        outputObservedAt: Date? = nil,
        titleObservedAt: Date? = nil,
        foregroundAgentStatusKey: String? = nil,
        foregroundObservedAt: Date? = nil,
        shellActivity: PanelShellActivityState = .unknown,
        shellActivityObservedAt: Date? = nil
    ) {
        self.lifecycle = lifecycle
        self.lifecycleObservedAt = lifecycleObservedAt
        self.lifecycleRuntimePIDKey = lifecycleRuntimePIDKey
        self.lifecycleRuntimeProcessIdentity = lifecycleRuntimeProcessIdentity
        self.lifecycleRevision = lifecycleRevision
        self.outputObservedAt = outputObservedAt
        self.titleObservedAt = titleObservedAt
        self.foregroundAgentStatusKey = foregroundAgentStatusKey
        self.foregroundObservedAt = foregroundObservedAt
        self.shellActivity = shellActivity
        self.shellActivityObservedAt = shellActivityObservedAt
    }
}

import CmuxWorkspaces
import Foundation

/// Timestamped observations used to derive one agent's status on one panel.
struct AgentStatusEvidence: Equatable, Sendable {
    var lifecycle: AgentHibernationLifecycleState?
    var lifecycleObservedAt: Date?
    var outputObservedAt: Date?
    var titleObservedAt: Date?
    var foregroundAgentStatusKey: String?
    var foregroundObservedAt: Date?
    var shellActivity: PanelShellActivityState

    init(
        lifecycle: AgentHibernationLifecycleState? = nil,
        lifecycleObservedAt: Date? = nil,
        outputObservedAt: Date? = nil,
        titleObservedAt: Date? = nil,
        foregroundAgentStatusKey: String? = nil,
        foregroundObservedAt: Date? = nil,
        shellActivity: PanelShellActivityState = .unknown
    ) {
        self.lifecycle = lifecycle
        self.lifecycleObservedAt = lifecycleObservedAt
        self.outputObservedAt = outputObservedAt
        self.titleObservedAt = titleObservedAt
        self.foregroundAgentStatusKey = foregroundAgentStatusKey
        self.foregroundObservedAt = foregroundObservedAt
        self.shellActivity = shellActivity
    }
}

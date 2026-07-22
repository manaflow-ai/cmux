import Foundation

struct AgentHibernationPlannerInput: Sendable {
    let key: AgentHibernationPanelKey
    let hasRestorableAgent: Bool
    let isLive: Bool
    let hasLiveProcess: Bool
    let isProtected: Bool
    let lifecycle: AgentHibernationLifecycleState
    let isTemporarilyUnableToProtect: Bool
    let hasUnconfirmedTerminalInput: Bool
    let lastActivityAt: TimeInterval

    init(
        key: AgentHibernationPanelKey,
        hasRestorableAgent: Bool,
        isLive: Bool,
        hasLiveProcess: Bool = false,
        isProtected: Bool,
        lifecycle: AgentHibernationLifecycleState,
        isTemporarilyUnableToProtect: Bool = false,
        hasUnconfirmedTerminalInput: Bool,
        lastActivityAt: TimeInterval
    ) {
        self.key = key
        self.hasRestorableAgent = hasRestorableAgent
        self.isLive = isLive
        self.hasLiveProcess = hasLiveProcess
        self.isProtected = isProtected
        self.lifecycle = lifecycle
        self.isTemporarilyUnableToProtect = isTemporarilyUnableToProtect
        self.hasUnconfirmedTerminalInput = hasUnconfirmedTerminalInput
        self.lastActivityAt = lastActivityAt
    }
}

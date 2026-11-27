import Foundation

struct AgentHibernationPlannerInput: Sendable {
    let key: AgentHibernationPanelKey
    let hasRestorableAgent: Bool
    let isLive: Bool
    /// Live-process evidence is used only to prove a lossless teardown scope;
    /// aggregate pressure never imposes a usage cap.
    let hasLiveProcess: Bool
    /// Whether the controller's trigger-specific process scope permits teardown.
    let processSafetyAllowsHibernation: Bool
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
        processSafetyAllowsHibernation: Bool,
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
        self.processSafetyAllowsHibernation = processSafetyAllowsHibernation
        self.isProtected = isProtected
        self.lifecycle = lifecycle
        self.isTemporarilyUnableToProtect = isTemporarilyUnableToProtect
        self.hasUnconfirmedTerminalInput = hasUnconfirmedTerminalInput
        self.lastActivityAt = lastActivityAt
    }
}

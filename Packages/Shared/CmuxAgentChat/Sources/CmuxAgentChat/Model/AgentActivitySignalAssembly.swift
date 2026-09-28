import Foundation

/// Combines the app's per-pane evidence into ``AgentActivitySignals``.
public struct AgentActivityEvidence: Sendable {
    /// The session registry's coarse lifecycle.
    public var registryState: ChatAgentState
    /// Whether the registry state came from hooks rather than process discovery.
    public var registryHasHookLifecycleState: Bool
    public var registryLastActivityAt: Date
    /// Turn facts folded from this session's hooks, when any arrived.
    public var hooks: AgentHookActivityState?
    /// The Feed's needs-input overlay (a permission, question or plan decision) is lit.
    public var feedDecisionPending: Bool
    /// Description of a command the agent runs in the terminal's foreground.
    public var foregroundCommand: String?
    /// The pane is local but its process census was unavailable or partial.
    public var foregroundCommandUnknown: Bool
    public var hasDraft: Bool?

    public init(
        registryState: ChatAgentState,
        registryHasHookLifecycleState: Bool,
        registryLastActivityAt: Date,
        hooks: AgentHookActivityState? = nil,
        feedDecisionPending: Bool = false,
        foregroundCommand: String? = nil,
        foregroundCommandUnknown: Bool = false,
        hasDraft: Bool? = nil
    ) {
        self.registryState = registryState
        self.registryHasHookLifecycleState = registryHasHookLifecycleState
        self.registryLastActivityAt = registryLastActivityAt
        self.hooks = hooks
        self.feedDecisionPending = feedDecisionPending
        self.foregroundCommand = foregroundCommand
        self.foregroundCommandUnknown = foregroundCommandUnknown
        self.hasDraft = hasDraft
    }

    public var signals: AgentActivitySignals {
        var signals = AgentActivitySignals()
        let registryEnded: Bool
        let registrySince: Date?
        let registryWorking: Bool
        let registryNeedsInput: Bool
        switch registryState {
        case .idle:
            (registryEnded, registrySince, registryWorking, registryNeedsInput) = (false, nil, false, false)
        case .working(let since):
            (registryEnded, registrySince, registryWorking, registryNeedsInput) = (false, since, true, false)
        case .needsInput(let since):
            (registryEnded, registrySince, registryWorking, registryNeedsInput) = (false, since, false, true)
        case .ended:
            (registryEnded, registrySince, registryWorking, registryNeedsInput) = (true, nil, false, false)
        }

        signals.ended = registryEnded || hooks?.ended == true
        signals.pendingQuestion = hooks?.pendingQuestion == true
        // The Feed overlay covers permissions, questions and plan approvals. A
        // question the hooks already saw stays a question.
        signals.pendingPermission = feedDecisionPending && !signals.pendingQuestion
        signals.openTool = hooks?.openTool
        // Hooks decide the turn only once they have seen a boundary; before that
        // (say, the app started mid-turn) the registry's working state stands.
        if let hooks, hooks.knowsTurnBoundary {
            signals.turnActive = hooks.turnActive
        } else {
            signals.turnActive = hooks?.turnActive == true || registryWorking
        }
        signals.lastToolFinished = hooks?.lastToolFinished == true
        signals.backgroundWork = hooks?.backgroundWork == true
        // Without a Feed decision or hook question, the registry's needs-input
        // comes from a notification: the turn is over and waits on a human.
        signals.awaitingInput = hooks?.awaitingInput == true
            || (registryNeedsInput && !feedDecisionPending && !signals.pendingQuestion && !signals.turnActive)
        // A background task is a child of the agent too; after Stop it is
        // background work, not a foreground command.
        if !(signals.backgroundWork && !signals.turnActive) {
            signals.foregroundCommand = foregroundCommand
        }
        signals.foregroundCommandUnknown = foregroundCommandUnknown
        signals.hasDraft = hasDraft
        signals.since = hooks?.since ?? registrySince ?? registryLastActivityAt
        signals.hasHookEvidence = hooks != nil || registryHasHookLifecycleState
        return signals
    }
}

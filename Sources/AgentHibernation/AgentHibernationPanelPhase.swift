enum AgentHibernationPanelPhase {
    case live
    case terminating(AgentHibernationPanelState)
    case recovering(AgentHibernationPanelState)
    case terminationFailed(AgentHibernationPanelState)
    case hibernated(AgentHibernationPanelState)

    var state: AgentHibernationPanelState? {
        switch self {
        case .live:
            nil
        case .terminating(let state),
             .recovering(let state),
             .terminationFailed(let state),
             .hibernated(let state):
            state
        }
    }

    var isCommitted: Bool {
        if case .live = self { return false }
        return true
    }

    /// The agent is down and its placeholder is committed. A pane still
    /// terminating, recovering or whose termination failed may still have a
    /// live process, so it does not count.
    var isSettledHibernation: Bool {
        if case .hibernated = self { return true }
        return false
    }

    var isTerminating: Bool {
        if case .terminating = self { return true }
        return false
    }

    var terminationFailed: Bool {
        if case .terminationFailed = self { return true }
        return false
    }

    var isAwaitingCommit: Bool {
        switch self {
        case .terminating, .recovering, .terminationFailed:
            true
        case .live, .hibernated:
            false
        }
    }
}

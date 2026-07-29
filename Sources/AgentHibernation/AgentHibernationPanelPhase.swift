import Foundation

struct AgentHibernationPanelState {
    let agent: SessionRestorableAgentSnapshot
    let hibernatedAt: Date
    let lastActivityAt: Date

    var agentDisplayName: String {
        agent.agentDisplayName
    }
}

enum AgentHibernationPanelPhase {
    case live
    case terminating(AgentHibernationPanelState)
    case hibernated(AgentHibernationPanelState)

    var state: AgentHibernationPanelState? {
        switch self {
        case .live:
            nil
        case .terminating(let state), .hibernated(let state):
            state
        }
    }

    var isCommitted: Bool {
        if case .live = self { return false }
        return true
    }

    var isTerminating: Bool {
        if case .terminating = self { return true }
        return false
    }
}

enum AgentHibernationResumePreparation: Equatable {
    case unavailable
    case resumed(queuedStartupInput: Bool)

    var didResume: Bool {
        if case .resumed = self { return true }
        return false
    }

    var queuedStartupInput: Bool {
        if case .resumed(let queuedStartupInput) = self { return queuedStartupInput }
        return false
    }
}

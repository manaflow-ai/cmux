import Foundation

extension AgentHibernationController {
    struct InFlightTeardown: Sendable {
        let requestID: UUID
        let trigger: AgentHibernationReclaimTrigger
    }

    enum ScopedProcessTerminationResult: Equatable, Sendable {
        case rejected
        case exited
        case committedAwaitingExit
    }

    struct CommittedTerminationObservation {
        let requestID: UUID
        let task: Task<Void, Never>
    }
}

import Foundation

extension AgentHibernationController {
    enum ScopedProcessTerminationResult: Equatable, Sendable {
        case rejected
        case exited
        case committedAwaitingExit
    }
}

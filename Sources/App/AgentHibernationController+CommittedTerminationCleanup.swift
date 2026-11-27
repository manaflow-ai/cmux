import Foundation

extension AgentHibernationController {
    struct CommittedTerminationCleanup {
        let requestID: UUID
        let task: Task<Void, Never>
    }
}

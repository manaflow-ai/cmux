import Foundation

extension AgentHibernationController {
    struct PostTeardownRestoreTask {
        let requestID: UUID
        let task: Task<Void, Never>
    }
}

import Foundation

extension AgentHibernationController {
    struct PostTeardownRestoreTask {
        let requestID: UUID
        let cancellationState: PostTeardownRestoreCancellationState
        let task: Task<Void, Never>
    }
}

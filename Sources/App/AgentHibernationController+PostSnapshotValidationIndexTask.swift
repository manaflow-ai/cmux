import Foundation

extension AgentHibernationController {
    struct PostSnapshotValidationIndexTask {
        let requestID: UUID
        let startSequence: UInt64
        let task: Task<RestorableAgentSessionIndex, Never>
    }
}

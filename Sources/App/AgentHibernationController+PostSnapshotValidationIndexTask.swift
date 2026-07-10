import Foundation

extension AgentHibernationController {
    struct PostSnapshotValidationIndexTask {
        let requestID: UUID
        var startSequence: UInt64
        var hasStartedCapture = true
        let task: Task<RestorableAgentSessionIndex?, Never>
    }
}

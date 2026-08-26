import Foundation

extension WorkstreamTaskToolTodos {
    /// An ordered pre-tool mutation waiting for its completed hook frame.
    struct PendingPreOperation: Sendable {
        let tool: WorkstreamTaskTool
        let inputJSON: String?
        let requestID: String?
        let assignedProvisionalID: String?
        var completion: PendingCompletion?
    }
}

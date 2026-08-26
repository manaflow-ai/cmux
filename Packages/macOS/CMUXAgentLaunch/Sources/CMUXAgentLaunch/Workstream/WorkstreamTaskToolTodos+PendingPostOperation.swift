import Foundation

extension WorkstreamTaskToolTodos {
    /// A completed hook frame retained until its matching pre-tool frame arrives.
    struct PendingPostOperation: Sendable {
        let tool: WorkstreamTaskTool
        let inputJSON: String?
        let responseJSON: String?
        let isError: Bool
        let requestID: String?
    }
}

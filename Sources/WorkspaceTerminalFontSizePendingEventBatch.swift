import Foundation

extension WorkspaceTerminalFontSizeCoordinator {
    struct PendingEventBatch {
        let windowDockSlotIdentity: ObjectIdentifier
        let lineage: EventBatchLineage
        var windowDockRequest: PendingRequest
        var workspaceRequests: [UUID: PendingRequest] = [:]
        var workspaceOrder: [UUID] = []
    }
}

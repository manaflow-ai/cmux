import Foundation

extension WorkspaceTerminalFontSizeCoordinator {
    struct PendingRequest {
        let token: UUID
        let sequence: UInt64
        let acceptedOrder: UInt64
        let resourceKey: RequestResourceKey
        let target: RequestTarget
        let batchLineage: EventBatchLineage
        /// Ordered Dock changes through this workspace's most recent event.
        /// This is a constant-size value transform, not a panel snapshot.
        var windowDockPrefixChange: WorkspaceTerminalFontSizeChange?
        var change: WorkspaceTerminalFontSizeChange
    }
}

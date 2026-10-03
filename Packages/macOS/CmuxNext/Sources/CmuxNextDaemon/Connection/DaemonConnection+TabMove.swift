import Foundation

extension DaemonConnection {
    /// Maps "unknown variant" (command not implemented by this daemon) to
    /// `missingCapabilities` so callers can hide or fall back.
    func requestNew<R: DaemonRequest>(_ request: R) async throws -> R.Response {
        do {
            return try await self.request(request)
        } catch DaemonError.command(let cmd, let message, _, _, _) where message.contains("unknown variant") {
            throw DaemonError.missingCapabilities([cmd])
        }
    }

    @discardableResult
    public func moveTab(_ surface: SurfaceID, to pane: PaneID, index: Int,
                        transaction: ClientTransactionID? = nil) async throws -> TabMoveResult {
        try await request(MoveTabRequest(surface: surface, pane: pane, index: index, transaction: transaction))
    }

    /// Moves a tab into an existing workspace, or a new one when `workspace` is nil.
    @discardableResult
    public func moveTab(_ surface: SurfaceID, toWorkspace workspace: WorkspaceHandle?,
                        transaction: ClientTransactionID? = nil) async throws -> TabMoveResult {
        try await request(MoveTabToWorkspaceRequest(surface: surface, workspace: workspace, transaction: transaction))
    }

    @discardableResult
    public func moveTabToSplit(_ surface: SurfaceID, pane: PaneID, edge: PaneEdge, ratio: Double? = nil,
                               transaction: ClientTransactionID? = nil) async throws -> TabMoveResult {
        try await requestNew(MoveTabToSplitRequest(surface: surface, pane: pane, edge: edge, ratio: ratio, transaction: transaction))
    }

    @discardableResult
    public func moveTabToColumn(_ surface: SurfaceID, target: ColumnDropTarget, afterColumn: ColumnID? = nil, width: Double? = nil,
                                sticky: StickySnapshot? = nil, transaction: ClientTransactionID? = nil) async throws -> TabMoveResult {
        try await requestNew(MoveTabToColumnRequest(surface: surface, target: target, afterColumn: afterColumn,
                                                    width: width, sticky: sticky, transaction: transaction))
    }

    /// New workspace holding the tab. On daemons without `tab-drag-v1` it
    /// falls back to `move-tab-to-workspace` with no destination (same
    /// outcome, without group placement).
    @discardableResult
    public func moveTabToNewWorkspace(_ surface: SurfaceID, group: WorkspaceGroupID? = nil, index: Int? = nil,
                                      transaction: ClientTransactionID? = nil) async throws -> TabMoveResult {
        do {
            return try await requestNew(MoveTabToNewWorkspaceRequest(surface: surface, group: group, index: index, transaction: transaction))
        } catch DaemonError.missingCapabilities {
            return try await moveTab(surface, toWorkspace: nil, transaction: transaction)
        }
    }
}

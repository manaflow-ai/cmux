import Foundation

extension DaemonConnection {
    /// Maps "unknown variant" (command not implemented by this daemon) to
    /// `missingCapabilities` so callers can hide or fall back.
    func requestNew<R: DaemonRequest>(_ request: R) async throws -> R.Response {
        do {
            return try await self.request(request)
        } catch DaemonError.command(let cmd, let message, _) where message.contains("unknown variant") {
            throw DaemonError.missingCapabilities([cmd])
        }
    }

    @discardableResult
    public func moveTab(_ surface: SurfaceID, to pane: PaneID, index: Int,
                        transaction: ClientTransactionID? = nil) async throws -> TabMoveResult {
        try await request(MoveTabRequest(surface: surface, pane: pane, index: index, clientTransactionID: transaction))
    }

    /// Moves a tab into an existing workspace, or a new one when `workspace` is nil.
    @discardableResult
    public func moveTab(_ surface: SurfaceID, toWorkspace workspace: WorkspaceHandle?,
                        transaction: ClientTransactionID? = nil) async throws -> TabMoveResult {
        try await request(MoveTabToWorkspaceRequest(surface: surface, workspace: workspace, clientTransactionID: transaction))
    }

    @discardableResult
    public func tabToNewSplit(_ surface: SurfaceID, pane: PaneID, edge: PaneEdge, ratio: Double? = nil,
                              transaction: ClientTransactionID? = nil) async throws -> TabMoveResult {
        try await requestNew(TabToNewSplitRequest(surface: surface, pane: pane, edge: edge, ratio: ratio, clientTransactionID: transaction))
    }

    @discardableResult
    public func tabToNewColumn(_ surface: SurfaceID, screen: ScreenID, afterColumn: ColumnID?, width: Double? = nil,
                               transaction: ClientTransactionID? = nil) async throws -> TabMoveResult {
        try await requestNew(TabToNewColumnRequest(surface: surface, screen: screen, afterColumn: afterColumn,
                                                   width: width, clientTransactionID: transaction))
    }

    /// New workspace holding the tab. Falls back to `move-tab-to-workspace`
    /// with no destination (same outcome, no name/group/index) on daemons
    /// without `tab-to-new-workspace`.
    @discardableResult
    public func tabToNewWorkspace(_ surface: SurfaceID, name: String? = nil, group: WorkspaceGroupID? = nil, index: Int? = nil,
                                  transaction: ClientTransactionID? = nil) async throws -> TabMoveResult {
        do {
            return try await requestNew(TabToNewWorkspaceRequest(surface: surface, name: name, key: .generate(), group: group,
                                                                 index: index, clientTransactionID: transaction))
        } catch DaemonError.missingCapabilities {
            return try await moveTab(surface, toWorkspace: nil, transaction: transaction)
        }
    }
}

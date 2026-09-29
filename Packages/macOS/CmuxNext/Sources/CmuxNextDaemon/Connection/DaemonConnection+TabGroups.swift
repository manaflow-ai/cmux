import Foundation

/// Chrome-style tab groups. TODO(feat-cmux-next-daemon): capability
/// `tab-groups-v1`; every call throws `DaemonError.missingCapabilities` on
/// daemons without it.
extension DaemonConnection {
    @discardableResult
    public func createTabGroup(in pane: PaneID, tabs: [SurfaceID], name: String? = nil, color: String? = nil,
                               transaction: ClientTransactionID? = nil) async throws -> TabGroupResult {
        try await requestNew(CreateTabGroupRequest(pane: pane, tabs: tabs, name: name, color: color, transaction: transaction))
    }

    @discardableResult
    public func updateTabGroup(_ group: TabGroupID, name: String? = nil, color: FieldUpdate<String> = .unchanged,
                               collapsed: Bool? = nil, transaction: ClientTransactionID? = nil) async throws -> TabGroupResult {
        try await requestNew(UpdateTabGroupRequest(group: group, name: name, color: color, collapsed: collapsed, transaction: transaction))
    }

    @discardableResult
    public func addTabs(_ tabs: [SurfaceID], toGroup group: TabGroupID, index: Int? = nil,
                        transaction: ClientTransactionID? = nil) async throws -> TabGroupResult {
        try await requestNew(AddTabsToGroupRequest(group: group, tabs: tabs, index: index, transaction: transaction))
    }

    @discardableResult
    public func removeTabsFromGroup(_ tabs: [SurfaceID], transaction: ClientTransactionID? = nil) async throws -> TabGroupResult {
        try await requestNew(RemoveTabsFromGroupRequest(tabs: tabs, transaction: transaction))
    }

    @discardableResult
    public func moveTabGroup(_ group: TabGroupID, to pane: PaneID, index: Int,
                             transaction: ClientTransactionID? = nil) async throws -> TabGroupResult {
        try await requestNew(MoveTabGroupRequest(group: group, pane: pane, index: index, transaction: transaction))
    }

    @discardableResult
    public func moveTabGroupToSplit(_ group: TabGroupID, pane: PaneID, edge: PaneEdge, ratio: Double? = nil,
                                    transaction: ClientTransactionID? = nil) async throws -> TabGroupResult {
        try await requestNew(MoveTabGroupToSplitRequest(group: group, pane: pane, edge: edge, ratio: ratio, transaction: transaction))
    }

    @discardableResult
    public func moveTabGroupToColumn(_ group: TabGroupID, target: ColumnDropTarget, afterColumn: ColumnID? = nil, width: Double? = nil,
                                     transaction: ClientTransactionID? = nil) async throws -> TabGroupResult {
        try await requestNew(MoveTabGroupToColumnRequest(group: group, target: target, afterColumn: afterColumn,
                                                         width: width, transaction: transaction))
    }

    @discardableResult
    public func moveTabGroupToNewWorkspace(_ group: TabGroupID, workspaceGroup: WorkspaceGroupID? = nil, index: Int? = nil,
                                           transaction: ClientTransactionID? = nil) async throws -> TabGroupResult {
        try await requestNew(MoveTabGroupToNewWorkspaceRequest(group: group, workspaceGroup: workspaceGroup, index: index,
                                                               transaction: transaction))
    }

    @discardableResult
    public func ungroupTabGroup(_ group: TabGroupID, transaction: ClientTransactionID? = nil) async throws -> TabGroupResult {
        try await requestNew(UngroupTabGroupRequest(group: group, transaction: transaction))
    }

    @discardableResult
    public func closeTabGroup(_ group: TabGroupID, transaction: ClientTransactionID? = nil) async throws -> TabGroupResult {
        try await requestNew(CloseTabGroupRequest(group: group, transaction: transaction))
    }

    // Saved groups

    @discardableResult
    public func saveTabGroup(_ group: TabGroupID) async throws -> SavedTabGroupSnapshot {
        try await requestNew(SaveTabGroupRequest(group: group)).saved
    }

    @discardableResult
    public func openSavedTabGroup(_ saved: SavedTabGroupID, in pane: PaneID? = nil, index: Int? = nil,
                                  transaction: ClientTransactionID? = nil) async throws -> TabGroupResult {
        try await requestNew(OpenSavedTabGroupRequest(saved: saved, pane: pane, index: index, transaction: transaction))
    }

    public func unsaveTabGroup(_ saved: SavedTabGroupID) async throws {
        _ = try await requestNew(UnsaveTabGroupRequest(saved: saved))
    }
}

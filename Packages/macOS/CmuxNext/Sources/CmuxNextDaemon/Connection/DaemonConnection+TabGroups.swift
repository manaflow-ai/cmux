import Foundation

/// Chrome-style tab groups (`tab-groups-v1`) and saved groups
/// (`saved-tab-groups-v1`). Every call throws
/// `DaemonError.missingCapabilities` on daemons without the command.
extension DaemonConnection {
    public func listTabGroups() async throws -> [TabGroupSnapshot] {
        try await requestNew(ListTabGroupsRequest()).groups
    }

    /// Groups `tabs`. The daemon derives the pane from the tabs; `pane` is
    /// kept for source compatibility and not sent.
    @discardableResult
    public func createTabGroup(in pane: PaneID? = nil, tabs: [SurfaceID], id: TabGroupID? = nil, name: String? = nil,
                               color: String? = nil, transaction: ClientTransactionID? = nil) async throws -> TabGroupResult {
        try await requestNew(CreateTabGroupRequest(tabs: tabs, group: id, name: name, color: color, transaction: transaction))
    }

    /// `transaction` is accepted for source compatibility; `update-tab-group`
    /// does not echo one (the change arrives as `tree-changed`).
    @discardableResult
    public func updateTabGroup(_ group: TabGroupID, name: String? = nil, color: FieldUpdate<String> = .unchanged,
                               collapsed: Bool? = nil, transaction: ClientTransactionID? = nil) async throws -> TabGroupResult {
        try await requestNew(UpdateTabGroupRequest(group: group, name: name, color: color, collapsed: collapsed))
    }

    /// Adds tabs at the end of the group. With `index` (position inside the
    /// group), each tab is then moved there with `move-tab`, a second commit.
    @discardableResult
    public func addTabs(_ tabs: [SurfaceID], toGroup group: TabGroupID, index: Int? = nil,
                        transaction: ClientTransactionID? = nil) async throws -> TabGroupResult {
        let result = try await requestNew(AddTabsToGroupRequest(group: group, tabs: tabs, transaction: transaction))
        guard let index, let pane = result.pane else { return result }
        guard let run = try await listTabGroups().first(where: { $0.id == group }), index < run.count - tabs.count else {
            return result
        }
        for (offset, surface) in tabs.enumerated() {
            _ = try await moveTab(surface, to: pane, index: run.start + index + offset, transaction: transaction)
        }
        return result
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

    /// `transaction` is accepted for source compatibility and not sent.
    @discardableResult
    public func ungroupTabGroup(_ group: TabGroupID, transaction: ClientTransactionID? = nil) async throws -> TabGroupResult {
        try await requestNew(UngroupTabGroupRequest(group: group))
    }

    /// `transaction` is accepted for source compatibility and not sent.
    @discardableResult
    public func closeTabGroup(_ group: TabGroupID, transaction: ClientTransactionID? = nil) async throws -> TabGroupResult {
        try await requestNew(CloseTabGroupRequest(group: group))
    }

    // Saved groups

    public func listSavedTabGroups() async throws -> [SavedTabGroupSnapshot] {
        try await requestNew(ListSavedTabGroupsRequest()).savedGroups
    }

    /// Saves a live group and returns its record (`save-tab-group` returns
    /// only the id, so this reads the record back with `list-saved-tab-groups`).
    @discardableResult
    public func saveTabGroup(_ group: TabGroupID) async throws -> SavedTabGroupSnapshot {
        let saved = try await requestNew(SaveTabGroupRequest(group: group)).saved
        var record = try await listSavedTabGroups().first { $0.id == saved } ?? SavedTabGroupSnapshot(id: saved)
        record.openGroup = group
        return record
    }

    /// Reopens a saved group into `pane`, then moves the group to `index`
    /// when given (a second commit). `pane` is required by the daemon.
    @discardableResult
    public func reopenSavedTabGroup(_ saved: SavedTabGroupID, in pane: PaneID, index: Int? = nil,
                                    transaction: ClientTransactionID? = nil) async throws -> TabGroupResult {
        let result = try await requestNew(ReopenSavedTabGroupRequest(saved: saved, pane: pane, transaction: transaction))
        guard let index, let group = result.groupID else { return result }
        return try await moveTabGroup(group, to: result.pane ?? pane, index: index, transaction: transaction)
    }

    @available(*, deprecated, renamed: "reopenSavedTabGroup(_:in:index:transaction:)")
    @discardableResult
    public func openSavedTabGroup(_ saved: SavedTabGroupID, in pane: PaneID? = nil, index: Int? = nil,
                                  transaction: ClientTransactionID? = nil) async throws -> TabGroupResult {
        guard let pane else { throw DaemonError.malformedResponse("reopen-saved-tab-group requires a pane") }
        return try await reopenSavedTabGroup(saved, in: pane, index: index, transaction: transaction)
    }

    /// Unsaves the record linked to a live group; the group stays.
    @discardableResult
    public func unsaveTabGroup(group: TabGroupID) async throws -> Bool {
        try await requestNew(UnsaveTabGroupRequest(group: group)).unsaved
    }

    /// Deletes a saved record by id (`delete-saved-tab-group`); a linked live
    /// group stays, unlinked.
    @discardableResult
    public func deleteSavedTabGroup(_ saved: SavedTabGroupID) async throws -> Bool {
        try await requestNew(DeleteSavedTabGroupRequest(saved: saved)).deleted
    }

    /// Deletes the saved record by id. Same as `deleteSavedTabGroup(_:)`.
    public func unsaveTabGroup(_ saved: SavedTabGroupID) async throws {
        _ = try await deleteSavedTabGroup(saved)
    }
}

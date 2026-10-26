import Foundation

/// A close of several selected rows as one action (`WorkspaceBulkClose`): one
/// question, one "Closed N workspaces" toast with Undo, and no group left empty.
extension SidebarModel {
    /// What a close of `id` from its menu or a key closes: the selected rows that can close
    /// (`canClose`), in row order, when `id` is one of two or more of them; otherwise `id` alone.
    public func closeTargets(for id: WorkspaceID) -> [WorkspaceID] {
        guard selection.count > 1, selection.contains(id), canClose(id) else { return [id] }
        let ids = orderedSelection.filter(canClose)
        return ids.count > 1 ? ids : [id]
    }

    /// Whether row `id` can go in a selection close: a closable workspace (not Home), not a
    /// placeholder, and not closing already (`ClosingWorkspaces`).
    public func canClose(_ id: WorkspaceID) -> Bool {
        guard let row = workspace(id), row.isClosable, !row.rowState.isPending else { return false }
        return !ClosingWorkspaces.shared.ids.contains(id.rawValue)
    }

    /// What a close of `ids` closes: the groups it empties (every workspace row of the group
    /// closes and it lists no link, tab or app), which close as Close Group does (an unpinned
    /// group goes, Undo brings it back), and the other rows of `ids`, in order.
    public func closePlan(_ ids: [WorkspaceID]) -> (groups: [SidebarGroup], rows: [WorkspaceID]) {
        let closing = Set(ids)
        let groups = SidebarEdits.groups(in: sections).filter { group in
            group.items.isEmpty && !group.workspaces.isEmpty && group.workspaces.allSatisfy { closing.contains($0.id) }
        }
        let grouped = Set(groups.flatMap(\.workspaces).map(\.id))
        return (groups, ids.filter { !grouped.contains($0) })
    }
}

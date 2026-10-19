import Foundation

/// A close of several selected rows as one action (`closeTargets`): one
/// question, one "Closed N workspaces" toast with Undo, and no group left empty.
extension SidebarModel {
    /// What a close of `ids` closes: the groups it empties (every workspace
    /// row closes and the group lists no link, tab or app), which close as
    /// Close Group does (an unpinned group goes, Undo brings it back), and
    /// the other rows of `ids`, in order.
    public func closePlan(_ ids: [WorkspaceID]) -> (groups: [SidebarGroup], rows: [WorkspaceID]) {
        let closing = Set(ids)
        let groups = self.groups.filter { group in
            group.items.isEmpty && !group.workspaces.isEmpty && group.workspaces.allSatisfy { closing.contains($0.id) }
        }
        let grouped = Set(groups.flatMap(\.workspaces).map(\.id))
        return (groups, ids.filter { !grouped.contains($0) })
    }

    /// Close Workspace's row menu title on `id`: "Close N Workspaces" when it
    /// closes the selection, nil (the catalog's title) for one row.
    public func closeTitle(for id: WorkspaceID) -> String? {
        let count = closeTargets(for: id).count
        guard count > 1 else { return nil }
        return String(localized: "sidebar.closeWorkspaces", defaultValue: "Close \(count) Workspaces", bundle: .module)
    }
}

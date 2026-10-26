import Foundation

/// A close of several selected rows that empties a group (`WorkspaceSelectionClose`): the group
/// closes as Close Group does instead of staying behind empty.
extension SidebarModel {
    /// The groups a close of `ids` empties: every workspace row of the group closes and it lists
    /// no link, tab or app, in sidebar order.
    public func groupsEmptied(byClosing ids: some Sequence<WorkspaceID>) -> [SidebarGroup] {
        let closing = Set(ids)
        return SidebarEdits.groups(in: sections).filter { group in
            group.items.isEmpty && !group.workspaces.isEmpty && group.workspaces.allSatisfy { closing.contains($0.id) }
        }
    }
}

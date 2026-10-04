public import AppKit

/// Where a workspace's row is in a sidebar, for anchors drawn outside the
/// sidebar (the agent cursor's other-workspace indicator). Computed from the
/// list layout, so it works for rows that have no view (the list realizes
/// only rows near its viewport).
public enum SidebarRowAnchor {
    /// The row of workspace `id` in `sidebar`'s coordinates (flipped). A
    /// workspace in a collapsed group answers its group row; a row scrolled
    /// out of the list is pinned to the nearest edge of the visible list,
    /// keeping its size. Nil when the sidebar does not list the workspace.
    public static func workspaceRow(_ id: WorkspaceID, in sidebar: SidebarView) -> CGRect? {
        let list = sidebar.list
        let layout = list.displayed
        let row = layout.row(for: .workspace(id)) ?? collapsedGroup(of: id, in: list).flatMap { layout.row(for: .group($0)) }
        guard let row else { return nil }
        let visible = list.enclosingScrollView?.contentView.bounds ?? list.bounds
        let rect = clamped(list.frame(for: row), into: visible)
        return list.convert(rect, to: sidebar)
    }

    private static func collapsedGroup(of id: WorkspaceID, in list: SidebarListView) -> GroupID? {
        list.groups.values.first { group in group.isCollapsed && group.workspaces.contains { $0.id == id } }?.id
    }

    /// `row` moved vertically into `area`, never taller than it.
    static func clamped(_ row: CGRect, into area: CGRect) -> CGRect {
        let height = min(row.height, area.height)
        let y = min(max(row.minY, area.minY), area.maxY - height)
        return CGRect(x: row.minX, y: y, width: row.width, height: height)
    }
}

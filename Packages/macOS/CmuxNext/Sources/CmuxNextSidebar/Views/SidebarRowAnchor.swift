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
        nil // red
    }

    /// `row` moved vertically into `area`, never taller than it.
    static func clamped(_ row: CGRect, into area: CGRect) -> CGRect {
        row // red
    }
}

public import Foundation

/// One recently focused workspace/panel exposed to interpreted custom
/// sidebars as a `recents` row.
public struct CustomSidebarRecentFocusSnapshot: Sendable, Equatable {
    /// The workspace that was focused.
    public let workspaceId: UUID
    /// The focused panel inside the workspace, when known.
    public let panelId: UUID?
    /// The workspace's display title at snapshot time.
    public let workspaceTitle: String
    /// The panel's display title at snapshot time, when known.
    public let panelTitle: String?
    /// Whether this item is older or newer than the current focus-history
    /// position.
    public let position: String
    /// When this focus target was focused.
    public let focusedAt: Date

    public init(
        workspaceId: UUID,
        panelId: UUID?,
        workspaceTitle: String,
        panelTitle: String?,
        position: String,
        focusedAt: Date
    ) {
        self.workspaceId = workspaceId
        self.panelId = panelId
        self.workspaceTitle = workspaceTitle
        self.panelTitle = panelTitle
        self.position = position
        self.focusedAt = focusedAt
    }
}

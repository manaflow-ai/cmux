public import Foundation

/// The full input the custom-sidebar interpreter data context is built from.
///
/// The app assembles this from the live tab manager, the per-workspace state,
/// and the current wall-clock instant on each `TimelineView` tick. The
/// data-context builder maps it to the top-level interpreter dictionary
/// (`workspaces`, `workspaceCount`, `selectedTitle`, `selectedId`,
/// `unreadTotal`, `clock`).
/// One workspace group's sidebar-relevant state, projected for the
/// interpreter data context.
public struct CustomSidebarGroupSnapshot: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let isCollapsed: Bool
    public let isPinned: Bool
    public let anchorWorkspaceId: UUID
    public let customColor: String?
    public let iconSymbol: String?

    public init(
        id: UUID,
        name: String,
        isCollapsed: Bool,
        isPinned: Bool,
        anchorWorkspaceId: UUID,
        customColor: String?,
        iconSymbol: String?
    ) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
        self.isPinned = isPinned
        self.anchorWorkspaceId = anchorWorkspaceId
        self.customColor = customColor
        self.iconSymbol = iconSymbol
    }
}

public struct CustomSidebarContextSnapshot: Sendable, Equatable {
    /// The ordered workspaces shown in the sidebar.
    public let workspaces: [CustomSidebarWorkspaceSnapshot]
    /// The window's workspace groups, in their display order.
    public let groups: [CustomSidebarGroupSnapshot]
    /// The selected workspace identifier, or `nil` when none is selected.
    public let selectedWorkspaceId: UUID?
    /// The selected workspace's display title, used for `selectedTitle`. Empty
    /// when nothing is selected.
    public let selectedWorkspaceTitle: String
    /// The total unread count across all workspaces (`unreadTotal`).
    public let totalUnreadCount: Int
    /// The wall-clock instant the `clock` object is derived from.
    public let now: Date

    /// Creates a context snapshot from already-resolved values.
    public init(
        workspaces: [CustomSidebarWorkspaceSnapshot],
        groups: [CustomSidebarGroupSnapshot] = [],
        selectedWorkspaceId: UUID?,
        selectedWorkspaceTitle: String,
        totalUnreadCount: Int,
        now: Date
    ) {
        self.workspaces = workspaces
        self.groups = groups
        self.selectedWorkspaceId = selectedWorkspaceId
        self.selectedWorkspaceTitle = selectedWorkspaceTitle
        self.totalUnreadCount = totalUnreadCount
        self.now = now
    }
}

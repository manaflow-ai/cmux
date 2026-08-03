public import Foundation

/// The full input the custom-sidebar interpreter data context is built from.
///
/// The app assembles this from the live tab manager, the per-workspace state,
/// and the current wall-clock instant on each `TimelineView` tick. The
/// data-context builder maps it to the top-level interpreter dictionary
/// (`workspaces`, `workspaceCount`, `selectedTitle`, `selectedId`,
/// `unreadTotal`, `creationContexts`, `selectedCreationContextId`, `clock`).
public struct CustomSidebarContextSnapshot: Sendable, Equatable {
    /// The ordered workspaces shown in the sidebar.
    public let workspaces: [CustomSidebarWorkspaceSnapshot]
    /// The selected workspace identifier, or `nil` when none is selected.
    public let selectedWorkspaceId: UUID?
    /// The selected workspace's display title, used for `selectedTitle`. Empty
    /// when nothing is selected.
    public let selectedWorkspaceTitle: String
    /// The total unread count across all workspaces (`unreadTotal`).
    public let totalUnreadCount: Int
    /// Execution contexts that can supply new-workspace and new-surface defaults.
    public let creationContexts: [CustomSidebarCreationContextSnapshot]
    /// The selected execution-context identifier.
    public let selectedCreationContextId: String
    /// The wall-clock instant the `clock` object is derived from.
    public let now: Date

    /// Creates a context snapshot from already-resolved values.
    public init(
        workspaces: [CustomSidebarWorkspaceSnapshot],
        selectedWorkspaceId: UUID?,
        selectedWorkspaceTitle: String,
        totalUnreadCount: Int,
        creationContexts: [CustomSidebarCreationContextSnapshot] = [],
        selectedCreationContextId: String = "automatic",
        now: Date
    ) {
        self.workspaces = workspaces
        self.selectedWorkspaceId = selectedWorkspaceId
        self.selectedWorkspaceTitle = selectedWorkspaceTitle
        self.totalUnreadCount = totalUnreadCount
        self.creationContexts = creationContexts
        self.selectedCreationContextId = selectedCreationContextId
        self.now = now
    }
}

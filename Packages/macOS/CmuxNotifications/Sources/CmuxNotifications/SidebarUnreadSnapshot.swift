public import Foundation

/// The unread values rendered for one workspace row.
public struct SidebarWorkspaceUnreadSummary: Equatable, Sendable {
    /// The workspace's displayed unread count.
    public var unreadCount: Int
    /// The trimmed body or title of the latest notification, when present.
    public var latestNotificationText: String?
    /// The stable identity of the latest notification, when present.
    public var latestNotificationId: UUID?
    /// The creation time of the latest notification, when present.
    public var latestNotificationCreatedAt: Date?
    /// Whether the workspace has a latest notification that can be cleared.
    public var hasLatestNotification: Bool

    /// Creates one workspace unread summary.
    public init(
        unreadCount: Int,
        latestNotificationText: String?,
        latestNotificationId: UUID? = nil,
        latestNotificationCreatedAt: Date? = nil,
        hasLatestNotification: Bool = false
    ) {
        self.unreadCount = unreadCount
        self.latestNotificationText = latestNotificationText
        self.latestNotificationId = latestNotificationId
        self.latestNotificationCreatedAt = latestNotificationCreatedAt
        self.hasLatestNotification = hasLatestNotification
    }
}

/// A workspace and optional surface pair in the unread set.
public struct SidebarSurfaceUnreadKey: Hashable, Sendable {
    /// The owning workspace identifier.
    public var workspaceId: UUID
    /// The surface identifier, or `nil` for a workspace-wide notification.
    public var surfaceId: UUID?

    /// Creates one workspace or surface unread key.
    public init(workspaceId: UUID, surfaceId: UUID?) {
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
    }
}

/// One atomic global unread-state publication shared by presentation surfaces.
public struct SidebarUnreadSnapshot: Equatable, Sendable {
    /// Total unread count rendered by global badges.
    public let totalUnreadCount: Int
    /// Per-workspace row summaries, omitting default empty summaries.
    public let summaryByWorkspaceId: [UUID: SidebarWorkspaceUnreadSummary]
    /// Workspace and surface pairs with notification-derived unread state.
    ///
    /// Owner-scoped manual surface state is published through
    /// ``SidebarSurfaceUnreadProjection`` so it does not invalidate unrelated
    /// global snapshot consumers.
    public let unreadSurfaceKeys: Set<SidebarSurfaceUnreadKey>
    /// Focused surfaces whose read indicator remains visible.
    public let focusedReadIndicatorByWorkspaceId: [UUID: UUID]
    /// Workspaces explicitly marked unread by the user.
    public let manualUnreadWorkspaceIds: Set<UUID>

    /// Creates one complete unread snapshot.
    public init(
        totalUnreadCount: Int = 0,
        summaryByWorkspaceId: [UUID: SidebarWorkspaceUnreadSummary] = [:],
        unreadSurfaceKeys: Set<SidebarSurfaceUnreadKey> = [],
        focusedReadIndicatorByWorkspaceId: [UUID: UUID] = [:],
        manualUnreadWorkspaceIds: Set<UUID> = []
    ) {
        self.totalUnreadCount = totalUnreadCount
        self.summaryByWorkspaceId = summaryByWorkspaceId
        self.unreadSurfaceKeys = unreadSurfaceKeys
        self.focusedReadIndicatorByWorkspaceId = focusedReadIndicatorByWorkspaceId
        self.manualUnreadWorkspaceIds = manualUnreadWorkspaceIds
    }

    /// Returns the workspace summary, or an empty summary when absent.
    public func summary(forWorkspaceId id: UUID) -> SidebarWorkspaceUnreadSummary {
        summaryByWorkspaceId[id] ?? SidebarWorkspaceUnreadSummary(
            unreadCount: 0,
            latestNotificationText: nil
        )
    }

    /// Returns the workspace's displayed unread count.
    public func unreadCount(forWorkspaceId id: UUID) -> Int {
        summary(forWorkspaceId: id).unreadCount
    }

    /// Returns the workspace's latest notification text.
    public func latestNotificationText(forWorkspaceId id: UUID) -> String? {
        summary(forWorkspaceId: id).latestNotificationText
    }

    /// Returns whether the workspace has any displayed unread state.
    public func workspaceIsUnread(forWorkspaceId id: UUID) -> Bool {
        unreadCount(forWorkspaceId: id) > 0 || hasManualUnread(forWorkspaceId: id)
    }

    /// Returns whether the workspace was explicitly marked unread.
    public func hasManualUnread(forWorkspaceId id: UUID) -> Bool {
        manualUnreadWorkspaceIds.contains(id)
    }

    /// Returns whether the workspace or surface has an unread notification.
    public func hasUnreadNotification(forWorkspaceId id: UUID, surfaceId: UUID?) -> Bool {
        unreadSurfaceKeys.contains(SidebarSurfaceUnreadKey(workspaceId: id, surfaceId: surfaceId))
    }

    /// Returns whether the surface should render its notification indicator.
    public func hasVisibleNotificationIndicator(forWorkspaceId id: UUID, surfaceId: UUID?) -> Bool {
        hasUnreadNotification(forWorkspaceId: id, surfaceId: surfaceId) ||
            (focusedReadIndicatorByWorkspaceId[id].map { $0 == surfaceId } ?? false)
    }

    /// Returns whether any supplied workspace can be marked read.
    public func canMarkWorkspaceRead(forWorkspaceIds ids: [UUID]) -> Bool {
        ids.contains { workspaceIsUnread(forWorkspaceId: $0) }
    }

    /// Returns whether any supplied workspace can be marked unread.
    public func canMarkWorkspaceUnread(forWorkspaceIds ids: [UUID]) -> Bool {
        ids.contains { !workspaceIsUnread(forWorkspaceId: $0) }
    }
}

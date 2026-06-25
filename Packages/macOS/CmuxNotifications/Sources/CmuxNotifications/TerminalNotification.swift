public import Foundation

/// A single terminal-originated notification entry: the value model the
/// notification store keeps, the sidebar/menu/feed render, the session snapshot
/// persists, and the iOS mirror forwards. Pure `Sendable` value type with no
/// reference to app-target state; the store owns the mutable list of these.
///
/// `tabId`/`surfaceId`/`panelId` locate the originating workspace and pane so
/// ``matches(tabId:surfaceId:)`` can route per-pane unread presentation;
/// `clickAction` carries the optional reveal-in-Finder action through the same
/// ``NotificationNavClickAction`` value the delivery and navigation coordinators
/// already consume.
public struct TerminalNotification: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let tabId: UUID
    public let surfaceId: UUID?
    public let panelId: UUID?
    public let title: String
    public let subtitle: String
    public let body: String
    public let createdAt: Date
    public var isRead: Bool
    public var paneFlash: Bool = true
    public var clickAction: NotificationNavClickAction?

    public init(
        id: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        panelId: UUID? = nil,
        title: String,
        subtitle: String,
        body: String,
        createdAt: Date,
        isRead: Bool,
        paneFlash: Bool = true,
        clickAction: NotificationNavClickAction? = nil
    ) {
        self.id = id
        self.tabId = tabId
        self.surfaceId = surfaceId
        self.panelId = panelId
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
        self.paneFlash = paneFlash
        self.clickAction = clickAction
    }

    /// Whether this entry belongs to the given tab and pane. A `nil`
    /// `targetSurfaceId` matches only workspace-level entries (no surface and no
    /// panel); otherwise it matches when either the surface or the panel id
    /// equals the target, so a panel-addressed query still finds a
    /// surface-addressed entry for the same pane and vice versa.
    public func matches(tabId targetTabId: UUID, surfaceId targetSurfaceId: UUID?) -> Bool {
        guard tabId == targetTabId else { return false }
        guard let targetSurfaceId else {
            return surfaceId == nil && panelId == nil
        }
        return surfaceId == targetSurfaceId || panelId == targetSurfaceId
    }
}

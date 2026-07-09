public import Foundation

/// A single terminal notification entry the store records and the UI renders.
///
/// Pure value type: identity, the owning workspace/surface/panel, the rendered
/// text, creation time, read/flash state, and an optional click action. It
/// reaches into no live state, so it lives in the notifications package and is
/// shared across the store, feed, sidebar, mobile mirror, and control socket.
public struct TerminalNotification: Identifiable, Hashable, Sendable {
    /// Stable identity of the notification entry.
    public let id: UUID
    /// The id of the workspace (tab) that owns the notification.
    public let tabId: UUID
    /// The id of the surface within the workspace, when scoped to one surface.
    public let surfaceId: UUID?
    /// The id of the panel within the workspace, when scoped to one panel.
    public let panelId: UUID?
    /// The notification title.
    public let title: String
    /// The notification subtitle.
    public let subtitle: String
    /// The notification body text.
    public let body: String
    /// When the notification was created.
    public let createdAt: Date
    /// Whether the notification has been read.
    public var isRead: Bool
    /// Whether the owning pane should flash to surface this notification.
    public var paneFlash: Bool = true
    /// Terminal scrollback position captured when the notification was recorded.
    public var scrollPosition: TerminalNotificationScrollPosition?
    /// The action performed when the notification is clicked, if any.
    public var clickAction: TerminalNotificationClickAction?

    /// Creates a terminal notification entry.
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
        scrollPosition: TerminalNotificationScrollPosition? = nil,
        clickAction: TerminalNotificationClickAction? = nil
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
        self.scrollPosition = scrollPosition
        self.clickAction = clickAction
    }

    /// Whether this notification targets the given workspace/surface. A `nil`
    /// target surface matches only a workspace-scoped notification (no surface
    /// and no panel); a concrete target matches when it equals either the
    /// surface or the panel.
    public func matches(tabId targetTabId: UUID, surfaceId targetSurfaceId: UUID?) -> Bool {
        guard tabId == targetTabId else { return false }
        guard let targetSurfaceId else {
            return surfaceId == nil && panelId == nil
        }
        return surfaceId == targetSurfaceId || panelId == targetSurfaceId
    }

    /// Recency ordering used to sort the store's notifications: newest
    /// (`createdAt` descending) first, with the id's UUID string breaking ties
    /// ascending so the order is stable. Suitable for `sorted(by:)`.
    public static func sortPrecedes(_ lhs: TerminalNotification, _ rhs: TerminalNotification) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

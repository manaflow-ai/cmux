public import Foundation

/// The persisted, `Codable` form of a single ``TerminalNotification`` recorded
/// in a session snapshot.
///
/// Pure value type carrying only the fields that survive a save/restore round
/// trip (identity, rendered text, creation time, read/flash state, and an
/// optional click action). It omits the live routing ids (`tabId`/`surfaceId`/
/// `panelId`), which restore re-supplies from the owning workspace/panel via
/// ``terminalNotification(tabId:surfaceId:panelId:)``. It reaches into no live
/// state, so it lives in the notifications package alongside the type it bridges.
public struct SessionNotificationSnapshot: Codable, Sendable {
    /// Stable identity of the notification entry.
    public var id: UUID
    /// The notification title.
    public var title: String
    /// The notification subtitle.
    public var subtitle: String
    /// The notification body text.
    public var body: String
    /// When the notification was created, as seconds since the Unix epoch.
    public var createdAt: TimeInterval
    /// Whether the notification has been read.
    public var isRead: Bool
    /// Whether the owning pane should flash; `nil` in legacy snapshots, restored
    /// as `true`.
    public var paneFlash: Bool?
    /// Terminal scrollback position captured when the notification was recorded.
    public var scrollPosition: TerminalNotificationScrollPosition?
    /// The action performed when the notification is clicked, if any.
    public var clickAction: TerminalNotificationClickAction?

    /// Creates a persisted notification snapshot from its individual fields.
    public init(
        id: UUID,
        title: String,
        subtitle: String,
        body: String,
        createdAt: TimeInterval,
        isRead: Bool,
        paneFlash: Bool? = nil,
        scrollPosition: TerminalNotificationScrollPosition? = nil,
        clickAction: TerminalNotificationClickAction? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
        self.paneFlash = paneFlash
        self.scrollPosition = scrollPosition
        self.clickAction = clickAction
    }

    /// Captures a live ``TerminalNotification`` into its persisted form, dropping
    /// the routing ids and storing `createdAt` as a Unix timestamp.
    public init(notification: TerminalNotification) {
        self.init(
            id: notification.id,
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body,
            createdAt: notification.createdAt.timeIntervalSince1970,
            isRead: notification.isRead,
            paneFlash: notification.paneFlash,
            scrollPosition: notification.scrollPosition,
            clickAction: notification.clickAction
        )
    }

    /// Rebuilds a live ``TerminalNotification`` for the given workspace/surface/
    /// panel, mapping `createdAt` back from its Unix timestamp and restoring a
    /// legacy absent `paneFlash` as `true`.
    public func terminalNotification(tabId: UUID, surfaceId: UUID?, panelId: UUID?) -> TerminalNotification {
        TerminalNotification(
            id: id,
            tabId: tabId,
            surfaceId: surfaceId,
            panelId: panelId,
            title: title,
            subtitle: subtitle,
            body: body,
            createdAt: Date(timeIntervalSince1970: createdAt),
            isRead: isRead,
            paneFlash: paneFlash ?? true,
            scrollPosition: scrollPosition,
            clickAction: clickAction
        )
    }
}

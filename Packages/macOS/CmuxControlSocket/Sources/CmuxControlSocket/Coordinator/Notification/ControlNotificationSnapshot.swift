public import Foundation

/// A read-only snapshot of one delivered terminal notification, as the app
/// target exposes it to ``ControlCommandCoordinator`` through
/// ``ControlNotificationContext``.
///
/// Mirrors the app target's `TerminalNotification` (plus the two app-resolved
/// adornments the legacy `notificationPayload` builder added: the ISO-8601
/// `createdAt` rendering and the workspace's tab title) without the package
/// importing the app target. The coordinator turns each snapshot into a
/// notification payload object, byte-identically to the former
/// `[String: Any]` builder.
public struct ControlNotificationSnapshot: Sendable, Equatable {
    /// The notification's stable identifier.
    public let id: UUID
    /// The workspace (tab) the notification belongs to.
    public let workspaceID: UUID
    /// The surface the notification targets, if any.
    public let surfaceID: UUID?
    /// The notification title.
    public let title: String
    /// The notification subtitle.
    public let subtitle: String
    /// The notification body.
    public let body: String
    /// The creation timestamp pre-rendered exactly as the legacy
    /// `notificationCreatedAtString` did (`ISO8601DateFormatter` with
    /// `.withInternetDateTime`, GMT). Carried as a string so the package never
    /// re-formats the date and the wire bytes stay identical.
    public let createdAtISO8601: String
    /// Whether the notification has been marked read.
    public let isRead: Bool
    /// The workspace's tab title, if the app could resolve one (the legacy
    /// `AppDelegate.tabTitle(for:)` read, written as `tab_title`).
    public let tabTitle: String?

    /// Creates a notification snapshot.
    ///
    /// - Parameters:
    ///   - id: The notification's stable identifier.
    ///   - workspaceID: The owning workspace (tab) id.
    ///   - surfaceID: The targeted surface, if any.
    ///   - title: The notification title.
    ///   - subtitle: The notification subtitle.
    ///   - body: The notification body.
    ///   - createdAtISO8601: The pre-rendered ISO-8601 creation timestamp.
    ///   - isRead: Whether the notification is read.
    ///   - tabTitle: The owning workspace's tab title, if any.
    public init(
        id: UUID,
        workspaceID: UUID,
        surfaceID: UUID?,
        title: String,
        subtitle: String,
        body: String,
        createdAtISO8601: String,
        isRead: Bool,
        tabTitle: String?
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAtISO8601 = createdAtISO8601
        self.isRead = isRead
        self.tabTitle = tabTitle
    }
}

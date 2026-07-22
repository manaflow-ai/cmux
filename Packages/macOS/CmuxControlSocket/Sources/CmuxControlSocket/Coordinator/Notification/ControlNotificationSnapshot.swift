public import Foundation

/// A read-only snapshot of one delivered terminal notification, as the app
/// target exposes it to ``ControlCommandCoordinator`` through
/// ``ControlNotificationContext``.
///
/// Mirrors the app target's `TerminalNotification` (plus the two app-resolved
/// adornments the legacy `notificationPayload` builder added: the creation
/// time and workspace tab title) without the package importing the app target.
/// The coordinator renders the timestamp while building the wire payload on
/// the socket worker.
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
    /// The creation timestamp. Kept as a Sendable value so full-list formatting
    /// can run after the bounded main-actor snapshot hop.
    public let createdAt: Date
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
    ///   - createdAt: The creation timestamp.
    ///   - isRead: Whether the notification is read.
    ///   - tabTitle: The owning workspace's tab title, if any.
    public init(
        id: UUID,
        workspaceID: UUID,
        surfaceID: UUID?,
        title: String,
        subtitle: String,
        body: String,
        createdAt: Date,
        isRead: Bool,
        tabTitle: String?
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
        self.tabTitle = tabTitle
    }
}

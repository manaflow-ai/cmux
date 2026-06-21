public import Foundation

/// The notification fields the session autosave fingerprint folds into its hash,
/// flattened off the app-target `TerminalNotification`.
///
/// Carries only the values the legacy `TabManager.hashNotifications` combined,
/// in order: id, title, subtitle, body, `createdAt` reduced to
/// `timeIntervalSince1970`, isRead, paneFlash, panelId, and the click action.
/// The click action is mirrored as ``ClickAction``, whose single-case shape
/// matches the app-target `TerminalNotificationClickAction` so Swift's
/// synthesized `Hashable` folds byte-identically into the fingerprint. The
/// app-side ``SessionFingerprintHosting`` witness maps live notifications into
/// these values; the service sorts them by `id.uuidString` exactly as before.
public struct SessionFingerprintNotificationSnapshot: Sendable, Equatable {
    /// The notification click action, mirroring the app-target
    /// `TerminalNotificationClickAction` case-for-case so its synthesized
    /// `Hashable` produces the same hash contribution as the legacy combine.
    public enum ClickAction: Sendable, Hashable {
        /// Legacy `TerminalNotificationClickAction.revealInFinder(path:)`.
        case revealInFinder(path: String)
    }

    /// Legacy `TerminalNotification.id`.
    public let id: UUID
    /// Legacy `TerminalNotification.title`.
    public let title: String
    /// Legacy `TerminalNotification.subtitle`.
    public let subtitle: String
    /// Legacy `TerminalNotification.body`.
    public let body: String
    /// Legacy `TerminalNotification.createdAt.timeIntervalSince1970`.
    public let createdAt: Double
    /// Legacy `TerminalNotification.isRead`.
    public let isRead: Bool
    /// Legacy `TerminalNotification.paneFlash`.
    public let paneFlash: Bool
    /// Legacy `TerminalNotification.panelId`.
    public let panelId: UUID?
    /// Legacy `TerminalNotification.clickAction`.
    public let clickAction: ClickAction?

    /// Creates a flattened notification fingerprint input.
    public init(
        id: UUID,
        title: String,
        subtitle: String,
        body: String,
        createdAt: Double,
        isRead: Bool,
        paneFlash: Bool,
        panelId: UUID?,
        clickAction: ClickAction?
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
        self.paneFlash = paneFlash
        self.panelId = panelId
        self.clickAction = clickAction
    }
}

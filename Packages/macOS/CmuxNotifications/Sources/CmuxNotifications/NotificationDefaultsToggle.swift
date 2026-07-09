public import Foundation

/// A single Boolean notification preference backed by `UserDefaults`, where an
/// absent stored value falls back to a fixed default.
///
/// Models the notification UI toggles (dock badge, unread pane ring, pane flash)
/// as value instances sharing one read rule, rather than as separate caseless-enum
/// namespaces each duplicating the key/default/lookup shape.
public struct NotificationDefaultsToggle: Sendable, Equatable {
    /// The `UserDefaults` key this toggle reads and writes.
    public let key: String

    /// The value used when `key` has no stored entry.
    public let defaultValue: Bool

    /// Creates a toggle bound to `key`, returning `defaultValue` when `key` is unset.
    public init(key: String, defaultValue: Bool) {
        self.key = key
        self.defaultValue = defaultValue
    }

    /// Returns the stored Boolean, or `defaultValue` when `key` is absent from `defaults`.
    public func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

extension NotificationDefaultsToggle {
    /// Whether the app shows an unread-count badge on its Dock icon.
    public static let dockBadge = NotificationDefaultsToggle(
        key: "notificationDockBadgeEnabled",
        defaultValue: true
    )

    /// Whether an unread terminal pane draws a highlight ring.
    public static let paneRing = NotificationDefaultsToggle(
        key: "notificationPaneRingEnabled",
        defaultValue: true
    )

    /// Whether a pane flashes when it receives a notification.
    public static let paneFlash = NotificationDefaultsToggle(
        key: "notificationPaneFlashEnabled",
        defaultValue: true
    )
}

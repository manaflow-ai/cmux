public import Foundation

/// Reads whether the macOS Dock badge for unread notifications is enabled.
///
/// A value type holding the `UserDefaults` it reads from, so the read is
/// injectable and testable instead of a caseless namespace reaching the process
/// `UserDefaults.standard`. The defaults key and its default value are the
/// wire-stable contract and stay byte-identical to the legacy
/// `notificationDockBadgeEnabled` key. Not `Sendable`: it stores a
/// non-`Sendable` `UserDefaults` reference.
public struct NotificationBadgeSettings {
    /// The `UserDefaults` key persisting whether the Dock badge is enabled.
    public static let dockBadgeEnabledKey = "notificationDockBadgeEnabled"
    /// The default Dock-badge-enabled value when the key is unset.
    public static let defaultDockBadgeEnabled = true

    private let defaults: UserDefaults

    /// Creates a reader bound to the given defaults store.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the Dock badge is enabled, falling back to the default when unset.
    public var isDockBadgeEnabled: Bool {
        if defaults.object(forKey: Self.dockBadgeEnabledKey) == nil {
            return Self.defaultDockBadgeEnabled
        }
        return defaults.bool(forKey: Self.dockBadgeEnabledKey)
    }
}

public import Foundation

/// Reads whether the unread-pane ring indicator is enabled.
///
/// A value type holding the `UserDefaults` it reads from. The defaults key and
/// its default value are the wire-stable contract and stay byte-identical to the
/// legacy `notificationPaneRingEnabled` key. Not `Sendable`: it stores a
/// non-`Sendable` `UserDefaults` reference.
public struct NotificationPaneRingSettings {
    /// The `UserDefaults` key persisting whether the pane ring is enabled.
    public static let enabledKey = "notificationPaneRingEnabled"
    /// The default pane-ring-enabled value when the key is unset.
    public static let defaultEnabled = true

    private let defaults: UserDefaults

    /// Creates a reader bound to the given defaults store.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the pane ring is enabled, falling back to the default when unset.
    public var isEnabled: Bool {
        if defaults.object(forKey: Self.enabledKey) == nil {
            return Self.defaultEnabled
        }
        return defaults.bool(forKey: Self.enabledKey)
    }
}

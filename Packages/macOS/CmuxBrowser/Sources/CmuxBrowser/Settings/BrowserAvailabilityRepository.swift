public import Foundation

/// Reads and writes the user's "disable the browser panel" override from `UserDefaults`.
///
/// This replaces the app target's caseless `BrowserAvailabilitySettings` namespace enum
/// (all-`static` `UserDefaults` accessors plus a change notification) with a value type that
/// takes its `UserDefaults` through the initializer, mirroring ``BrowserDevToolsButtonDebugRepository``.
/// The `static let` key, change-notification name, and default stay byte-identical to the app
/// target so the persisted value and the change notification agree across the running app:
/// every poster/observer of ``didChangeNotification`` keeps using the same `Notification.Name`,
/// and the `@AppStorage`/`UserDefaults` readers keep resolving the same ``disabledKey``.
public struct BrowserAvailabilityRepository {
    /// The `UserDefaults` key storing the browser-disabled override flag.
    public static let disabledKey = "browserDisabledOverride"

    /// Posted (with a `nil` object) whenever the browser-disabled override changes, so
    /// observers can re-evaluate browser availability.
    public static let didChangeNotification = Notification.Name("cmux.browserAvailabilityDidChange")

    /// The shipped default: the browser panel is available (not disabled) when nothing is stored.
    public static let defaultDisabled = false

    private let defaults: UserDefaults

    /// Creates a repository backed by the given `UserDefaults`.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the browser panel is currently disabled, falling back to ``defaultDisabled``
    /// when no value is stored.
    public func isDisabled() -> Bool {
        // No synchronize() on read: it forces a blocking prefs-plist reload on a path hit from link-open/pane-create; UserDefaults stays coherent in-process and via cfprefsd.
        if defaults.object(forKey: Self.disabledKey) == nil {
            return Self.defaultDisabled
        }
        return defaults.bool(forKey: Self.disabledKey)
    }

    /// Whether the browser panel is currently enabled, i.e. the inverse of ``isDisabled()``.
    public func isEnabled() -> Bool {
        !isDisabled()
    }

    /// Persists the browser-disabled override and posts ``didChangeNotification``.
    public func setDisabled(_ disabled: Bool) {
        // `set` already persists; `synchronize()` is a deprecated no-op-style fsync.
        defaults.set(disabled, forKey: Self.disabledKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}

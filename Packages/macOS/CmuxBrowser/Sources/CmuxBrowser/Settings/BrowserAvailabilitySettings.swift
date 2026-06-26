public import Foundation

/// Reads and toggles the persisted "cmux browser disabled" override.
///
/// A single `UserDefaults` flag (under ``disabledKey``) records whether the
/// embedded cmux browser is force-disabled; when unset it falls back to
/// ``defaultDisabled``. ``isDisabled(defaults:)`` reads the flag,
/// ``isEnabled(defaults:)`` is its negation, and ``setDisabled(_:defaults:)``
/// persists the flag and posts ``didChangeNotification`` so observers can
/// re-evaluate availability.
///
/// Static members only: a wire-affecting `UserDefaults` key, a notification
/// name, a default, and pure read/write transforms over the injected defaults,
/// so there is no per-instance state to hold (one-line justification per the
/// no-namespace-enum convention). lint:allow namespace-type — wire-affecting
/// constants plus stateless UserDefaults transforms, no per-instance state.
public struct BrowserAvailabilitySettings {
    /// `UserDefaults` key under which the browser-disabled override is persisted.
    public static let disabledKey = "browserDisabledOverride"

    /// Posted after ``setDisabled(_:defaults:)`` so observers re-evaluate
    /// browser availability.
    public static let didChangeNotification = Notification.Name("cmux.browserAvailabilityDidChange")

    /// The disabled state used when no value is stored.
    public static let defaultDisabled = false

    /// Whether the embedded browser is force-disabled.
    ///
    /// - Parameter defaults: The defaults to read the override from.
    /// - Returns: The stored flag, or ``defaultDisabled`` when unset.
    public static func isDisabled(defaults: UserDefaults = .standard) -> Bool {
        // No synchronize() on read: it forces a blocking prefs-plist reload on a path hit from link-open/pane-create; UserDefaults stays coherent in-process and via cfprefsd.
        if defaults.object(forKey: disabledKey) == nil {
            return defaultDisabled
        }
        return defaults.bool(forKey: disabledKey)
    }

    /// Whether the embedded browser is available (the negation of
    /// ``isDisabled(defaults:)``).
    ///
    /// - Parameter defaults: The defaults to read the override from.
    /// - Returns: `true` when the browser is enabled.
    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        !isDisabled(defaults: defaults)
    }

    /// Persists the disabled override and notifies observers.
    ///
    /// - Parameters:
    ///   - disabled: The new disabled state.
    ///   - defaults: The defaults to write the override to.
    public static func setDisabled(_ disabled: Bool, defaults: UserDefaults = .standard) {
        // `set` already persists; `synchronize()` is a deprecated no-op-style fsync.
        defaults.set(disabled, forKey: disabledKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

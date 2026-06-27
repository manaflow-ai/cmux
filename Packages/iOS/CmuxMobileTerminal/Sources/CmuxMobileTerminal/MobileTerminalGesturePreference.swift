import Foundation

/// Persisted "one-finger selects" gesture mode for the mobile terminal.
///
/// When enabled (the default), a one-finger drag on the terminal selects text
/// and a two-finger drag scrolls; when disabled, a one-finger drag scrolls (the
/// original behavior) and the selection drag is turned off. The toggle lives in
/// Settings ▸ Terminal and is applied live: ``GhosttySurfaceView`` observes
/// ``didChangeNotification`` and re-arms its recognizers without a relaunch.
///
/// ```swift
/// let gestures = MobileTerminalGesturePreference()
/// gestures.oneFingerSelects = false   // revert to one-finger scrolling
/// ```
@MainActor
public final class MobileTerminalGesturePreference {
    /// Posted whenever ``oneFingerSelects`` is written so a live surface can
    /// re-apply its gesture configuration immediately.
    public static let didChangeNotification = Notification.Name("MobileTerminalGesturePreferenceDidChange")

    private static let oneFingerSelectsKey = "cmux.terminal.oneFingerSelects.v1"

    private let defaults: UserDefaults

    /// Creates a preference store.
    ///
    /// - Parameter defaults: The backing store. Tests pass a
    ///   `UserDefaults(suiteName:)` so they never touch the developer's
    ///   settings; production uses `.standard`.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether a one-finger drag selects text (two fingers scroll). Defaults to
    /// `true` until the user explicitly turns it off.
    public var oneFingerSelects: Bool {
        get {
            guard defaults.object(forKey: Self.oneFingerSelectsKey) != nil else { return true }
            return defaults.bool(forKey: Self.oneFingerSelectsKey)
        }
        set {
            defaults.set(newValue, forKey: Self.oneFingerSelectsKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }
}

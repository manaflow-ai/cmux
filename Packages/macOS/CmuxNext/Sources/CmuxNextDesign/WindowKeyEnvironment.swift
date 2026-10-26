import AppKit
import CmuxNextWakeups

/// What ``WindowKeyFamily`` reads about the keyboard and when it decides: the live app by
/// default, a test's own events, key window, activation state and turn runner otherwise.
@MainActor
struct WindowKeyEnvironment {
    /// The app's events the key and activation notices arrive through, injected by the composition
    /// root (``WindowMaterialView/observeKeyFamily(of:through:)``). Nil for a window it did not set
    /// up: that window's tracker observes `NotificationCenter.default` itself.
    var events: AppEvents?
    /// Where `appearance.inactiveWindowDim` changes arrive (the app's ``AppearanceSignals``).
    var appearance: AppearanceSignals = DesignSettings.shared.signals
    /// The key window now (`NSApp.keyWindow`).
    var keyWindow: @MainActor () -> NSWindow? = { NSApp.keyWindow }
    /// Whether this app is active (`NSApp.isActive`).
    var isAppActive: @MainActor () -> Bool = { NSApp.isActive }
    /// Runs a key change's check on the next main-actor turn (a resign posts before the next
    /// window becomes key). Tests run the checks themselves.
    var nextTurn: @MainActor (_ check: @escaping @MainActor () -> Void) -> Void = { check in
        Task { @MainActor in check() }
    }

    /// The running app.
    static var live: WindowKeyEnvironment { WindowKeyEnvironment() }
}

import AppKit

/// What ``WindowKeyFamily`` reads about the keyboard and when it decides: the live app by
/// default, a test's own center, key window, activation state and turn runner otherwise.
@MainActor
struct WindowKeyEnvironment {
    /// The center the key and activation notices arrive on.
    var center: NotificationCenter = .default
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

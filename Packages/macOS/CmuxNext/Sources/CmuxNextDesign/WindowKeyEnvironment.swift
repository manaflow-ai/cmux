import AppKit
import CmuxNextCompat

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
    /// Runs a key change's check after the notices of the change have posted (a resign posts
    /// before the next window becomes key), as a main run loop block: blocks run before the
    /// pass's `beforeWaiting` stage, where Core Animation commits AppKit's key-state redraw, so
    /// the wash the check sets lands in that same commit. Tests run the checks themselves.
    var nextTurn: @MainActor (_ check: @escaping @MainActor () -> Void) -> Void = { check in
        MainRunLoopBlock.perform { check() }
    }

    /// The running app.
    static var live: WindowKeyEnvironment { WindowKeyEnvironment() }
}

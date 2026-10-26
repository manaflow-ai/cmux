public import CoreGraphics
public import Foundation

/// What ``SessionInputPending`` reads from the window server and AppKit: the seam its tests replace
/// (``WindowServerInputEvents`` in the app).
@MainActor
public protocol SessionInputEvents: AnyObject {
    /// Seconds since the window server generated the last input event of any type in this login
    /// session (`kCGAnyInputEventType`): one query that rules out every pending key and click when
    /// nothing newer than the last dispatched event exists.
    func secondsSinceLastInput() -> TimeInterval
    /// Seconds since the window server generated the last event of `type` in this login session.
    func secondsSinceLastEvent(_ type: CGEventType) -> TimeInterval
    /// Whether this app is active (the session's keys and clicks are its own).
    var isAppActive: Bool { get }
    /// The main screen's refresh interval in seconds (`NSScreen.minimumRefreshInterval`): an
    /// undispatched event stops counting after two of them.
    var refreshInterval: TimeInterval { get }
    /// Starts reporting every input event AppKit dispatches in this app (keys, modifier changes,
    /// mouse buttons, pointer motion, scrolls): its timestamp (seconds since boot) and kind.
    /// Returns false while it cannot yet (no `NSApp`): the caller asks again on its next check.
    func observeDispatch(_ dispatched: @escaping @MainActor @Sendable (SessionInputPending.Dispatched) -> Void) -> Bool
}

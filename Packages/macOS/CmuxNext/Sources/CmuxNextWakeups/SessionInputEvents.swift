public import CoreGraphics
public import Foundation

/// What ``SessionInputPending`` reads from the window server and AppKit: the seam its tests replace
/// (``WindowServerInputEvents`` in the app).
@MainActor
public protocol SessionInputEvents: AnyObject {
    /// Seconds since the window server generated the last event of `type` in this login session.
    func secondsSinceLastEvent(_ type: CGEventType) -> TimeInterval
    /// Whether this app is active (the session's keys and clicks are its own).
    var isAppActive: Bool { get }
    /// Starts reporting, through `dispatched`, the timestamp (seconds since boot) of every key-down
    /// and mouse-button-down event AppKit dispatches in this app. Returns false while it cannot yet
    /// (no `NSApp`): the caller asks again on its next check.
    func observeDispatch(_ dispatched: @escaping @MainActor @Sendable (TimeInterval) -> Void) -> Bool
}

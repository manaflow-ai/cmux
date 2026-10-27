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
    /// The refresh interval in seconds of the display the person works on (the key window's
    /// screen, else the main screen: `NSScreen.minimumRefreshInterval`): an undispatched event
    /// stops counting after two of them.
    var refreshInterval: TimeInterval { get }
    /// Whether the topmost window under the pointer is one of this app's: macOS sends a scroll
    /// there, so only then can a scroll on its way be this app's.
    var pointerIsOverAppWindow: Bool { get }
    /// Starts reporting every input event AppKit dispatches in this app (keys, modifier changes,
    /// mouse buttons, pointer motion, scrolls): its timestamp (seconds since boot) and kind.
    /// ``SessionInputPending`` calls it once, from its init.
    func observeDispatch(_ dispatched: @escaping @MainActor @Sendable (SessionInputPending.Dispatched) -> Void)
}

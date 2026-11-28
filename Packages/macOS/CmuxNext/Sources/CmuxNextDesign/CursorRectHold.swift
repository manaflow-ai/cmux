public import AppKit

/// A pane's say over its own cursor-rect invalidations, asked by the window that hosts it
/// (`CursorRectHoldHosting`). The window only forwards; what is held, and when it is given back,
/// is the policy's. The one policy today is Home's typing hold (CmuxNextHome `HomeCursorRectHold`).
@MainActor
public protocol CursorRectHoldPolicy: AnyObject {
    /// Before the window handles `event`.
    func windowWillSend(_ event: NSEvent, in window: NSWindow)
    /// True when the policy keeps `view`'s invalidation for later; it re-issues it on `window`
    /// (`invalidateCursorRects(for:)`), and answers false for that call.
    func holdsInvalidation(for view: NSView, in window: NSWindow) -> Bool
    /// The window becomes or stops being key: every kept invalidation goes back to the window.
    func windowKeyStateWillChange(_ window: NSWindow)
    /// The window's first responder changed (also when code moves the focus, without an event).
    func firstResponderDidChange(in window: NSWindow)
}

/// A window that asks a `CursorRectHoldPolicy` (cmux-next's shell window). It keeps the policy weakly.
@MainActor
public protocol CursorRectHoldHosting: NSWindow {
    var cursorRectHold: (any CursorRectHoldPolicy)? { get set }
}

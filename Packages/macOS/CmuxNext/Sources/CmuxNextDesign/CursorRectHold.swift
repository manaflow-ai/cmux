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

/// A view that sets its cursor from a hit test of each pointer event (`cursorUpdate`, `mouseMoved` in its tracking
/// area) and adds no cursor rects, as Chrome sets the cursor from the hit test of the mouse event. AppKit invalidates
/// the cursor rects of every view whose frame moves, and each invalidation rebuilds the window's structural regions
/// (drag margins and a constraint min-size walk of every view) in that display cycle; for such a view there is nothing
/// to invalidate, so the window skips it (cmux-next's shell window). HOT PATH AUDIT frames: a divider moves in every
/// frame of a spring or a drag.
@MainActor
public protocol HitTestCursorView: NSView {}

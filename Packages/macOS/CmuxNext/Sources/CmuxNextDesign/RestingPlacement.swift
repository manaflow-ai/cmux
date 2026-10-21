public import AppKit

/// A view a layout spring shows away from where it will rest: a pane host
/// while the strip camera scrolls, or a split pane sliding in. Window-relative
/// chrome inside it (a tab strip clearing the traffic lights) measures against
/// the rest, so it lays out once, at its final place, and then moves rigidly
/// with the view instead of laying out again on every frame of the motion.
@MainActor
public protocol RestingPlacement: NSView {
    /// Where the view will rest minus where it shows now, in its superview's points.
    var restOffset: CGVector { get }
    /// Whether the view's frame is still on a layout spring (a zoom, a split, a close): it moves
    /// or resizes on every display frame until the spring lands. Content whose resize is costly
    /// (a terminal's PTY grid) waits for the landing (``PaneMotionSettling``).
    var isOnLayoutSpring: Bool { get }
}

public extension RestingPlacement {
    var isOnLayoutSpring: Bool { restOffset != .zero }
}

/// A view inside a ``RestingPlacement`` that defers costly work while its placement is on a layout
/// spring and does it once when the spring lands. A terminal reports its new grid (one PTY resize,
/// one shell redraw) there instead of on every frame of a Cmd-Shift-Enter zoom.
@MainActor
public protocol PaneMotionSettling: NSView {
    /// The enclosing placement's spring landed: the view's frame is final.
    func paneMotionDidSettle()
}

/// A window whose chrome resizes the content area over several frames: the sidebar sliding
/// open or closed moves the content edge on every display frame of its width animation, which
/// resizes every pane in it. Content whose resize is costly defers it to the landing, as it
/// does inside a pane's own layout spring (``RestingPlacement``).
@MainActor
public protocol ContentAreaMotionHosting: NSWindow {
    /// Whether the window's chrome is resizing the content area on an animation now.
    var isContentAreaInMotion: Bool { get }
}

public extension NSView {
    /// Whether the nearest enclosing ``RestingPlacement`` is still on a layout spring, or the
    /// window's chrome is resizing the content area (``ContentAreaMotionHosting``).
    var isInPaneMotion: Bool {
        if let host = window as? any ContentAreaMotionHosting, host.isContentAreaInMotion { return true }
        var ancestor = superview
        while let view = ancestor {
            if let placement = view as? RestingPlacement { return placement.isOnLayoutSpring }
            ancestor = view.superview
        }
        return false
    }

    /// Tells every ``PaneMotionSettling`` view in this subtree (this view included) that its
    /// placement's spring landed.
    func notifyPaneMotionSettled() {
        if let settling = self as? PaneMotionSettling { settling.paneMotionDidSettle() }
        for subview in subviews { subview.notifyPaneMotionSettled() }
    }
}

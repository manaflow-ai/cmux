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
    /// While on a layout spring that changes its content's size: how much larger (negative: smaller) its
    /// content area will rest than it is now, in points, as ``PaneMotionTargeting/paneMotionWillRest(sizeChange:)``
    /// gives it at the spring's start. A view that joins the content mid-spring (a split's new pane gets its
    /// terminal from the daemon's echo) asks for it here. Nil at rest or with no size change.
    var restContentSizeChange: CGSize? { get }
}

public extension RestingPlacement {
    var isOnLayoutSpring: Bool { restOffset != .zero }
    var restContentSizeChange: CGSize? { nil }
}

public extension NSView {
    /// The nearest enclosing ``RestingPlacement``'s ``RestingPlacement/restContentSizeChange``: the size change
    /// this view's spring will rest at, for a view that joins mid-spring. Nil outside a spring.
    var enclosingRestSizeChange: CGSize? {
        var ancestor = superview
        while let view = ancestor {
            if let placement = view as? RestingPlacement { return placement.isOnLayoutSpring ? placement.restContentSizeChange : nil }
            ancestor = view.superview
        }
        return nil
    }
}

/// A view inside a ``RestingPlacement`` that defers costly work while its placement is on a layout
/// spring and does it once when the spring lands. A terminal reports its new grid (one PTY resize,
/// one shell redraw) there instead of on every frame of a Cmd-Shift-Enter zoom.
@MainActor
public protocol PaneMotionSettling: NSView {
    /// The enclosing placement's spring landed: the view's frame is final.
    func paneMotionDidSettle()
}

/// A view inside a ``RestingPlacement`` that wants its final size when a layout spring starts (or retargets,
/// a press during the motion), not when it lands: a terminal sends its final grid to its PTY at the start
/// of a split or close and draws each frame's size meanwhile. Called once per start or retarget, never per
/// frame, and never for a placement that only moves.
@MainActor
public protocol PaneMotionTargeting: NSView {
    /// The enclosing placement's content area will rest `sizeChange` larger (negative: smaller) than it is
    /// now, in points; the pane chrome around this view does not change size during a spring, so this
    /// view's final size is `bounds.size + sizeChange`.
    /// - Returns: The edge held content taller than its clip should be pinned to during the spring
    ///   (``PaneMotionAnchor``): a terminal whose prompt is on its last row answers `.bottom`.
    func paneMotionWillRest(sizeChange: CGSize) -> PaneMotionAnchor
}

/// A view inside a pane that follows a person's resize drag (a split divider, a column or row edge) its own
/// way. A Chromium page cannot lay out in the frame its pane takes a new size (the page is drawn by another
/// process some frames later), so it keeps the size it had when the drag began, anchored at its top-left
/// corner and clipped to the pane, and lays out once at the pane's final size.
@MainActor
public protocol PaneResizeGestureFollowing: NSView {
    /// `true` when the drag begins, `false` once the drag ended and the motion its release started landed:
    /// the pane's frame is final. Called once each, never per frame.
    func paneResizeGestureDidChange(active: Bool)
}

/// The vertical edge a pane's held content rides during a layout spring (``PaneMotionTargeting``).
public enum PaneMotionAnchor: Sendable {
    /// Pinned at the top (the default).
    case top
    /// Pinned at the bottom: the content's last row stays in view while the pane grows or shrinks.
    case bottom
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

    /// Tells every ``PaneMotionTargeting`` view in this subtree (this view included) the size change its
    /// placement's spring will rest at. Returns `.bottom` when any of them asks for it, else `.top`.
    @discardableResult
    func notifyPaneMotionWillRest(sizeChange: CGSize) -> PaneMotionAnchor {
        var anchor = (self as? PaneMotionTargeting)?.paneMotionWillRest(sizeChange: sizeChange) ?? .top
        for subview in subviews where subview.notifyPaneMotionWillRest(sizeChange: sizeChange) == .bottom { anchor = .bottom }
        return anchor
    }

    /// Every ``PaneResizeGestureFollowing`` view in this subtree (this view included), to tell a resize drag's
    /// start and, later, its end.
    func paneResizeGestureFollowers() -> [any PaneResizeGestureFollowing] {
        var found: [any PaneResizeGestureFollowing] = []
        if let follower = self as? PaneResizeGestureFollowing { found.append(follower) }
        for subview in subviews { found += subview.paneResizeGestureFollowers() }
        return found
    }

    /// Tells every ``PaneMotionSettling`` view in this subtree (this view included) that its
    /// placement's spring landed.
    func notifyPaneMotionSettled() {
        if let settling = self as? PaneMotionSettling { settling.paneMotionDidSettle() }
        for subview in subviews { subview.notifyPaneMotionSettled() }
    }
}

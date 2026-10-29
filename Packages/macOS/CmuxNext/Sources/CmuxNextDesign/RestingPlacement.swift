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
    /// Whether the view's frame is where it rests, or is set there in this turn, although it may be on a layout
    /// spring: the render server shows that spring (`PaneHostView.placeAtRest`). False on a CPU spring, whose
    /// frame moves on every display frame. True at rest.
    var framePlacedAtRest: Bool { get }
    /// What pages in the view do while it springs (``PageSpringResizing``); nil: they resize with it.
    var pageResizing: PageSpringResizing? { get }
    /// Whether Core Animation shows the view moving or resizing away from its frame, which is already at rest
    /// (a render-server spring): content placed from its frame in another window (a Chromium page window) is
    /// at the rest place, not where the view shows. Its changes reach ``PaneRenderMoveObserving`` views.
    var showsRenderMove: Bool { get }
}

public extension RestingPlacement {
    var isOnLayoutSpring: Bool { restOffset != .zero }
    var restContentSizeChange: CGSize? { nil }
    var framePlacedAtRest: Bool { !isOnLayoutSpring }
    var pageResizing: PageSpringResizing? { nil }
    var showsRenderMove: Bool { false }
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

    /// The nearest enclosing ``RestingPlacement``'s ``RestingPlacement/framePlacedAtRest``; true outside one.
    var enclosingFramePlacedAtRest: Bool {
        var ancestor = superview
        while let view = ancestor {
            if let placement = view as? RestingPlacement { return placement.framePlacedAtRest }
            ancestor = view.superview
        }
        return true
    }
}

/// A view inside a pane host that follows the host's place in its window once per finished move, never per
/// frame: a strip or canvas camera that landed, a pan that ended, a spring that landed, a pane moved by a
/// close or a reorder with no animation. The layout calls it after the frame the move rests in, once the
/// layout is out of motion (`LayoutRootView.setLayoutInMotion`); a page's glass pushes its lens rect there.
@MainActor
public protocol PanePlacementFollowing: NSView {
    /// The enclosing pane host's place in its window changed since the last call and is final now.
    func panePlacementDidSettle()
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

/// A view that may hold its content at the size its pane rests at while the pane springs: the terminal's surface hold
/// (`TerminalHostView`) and a page's spring hold (`CEFHostView`, `WebKitPageContainer`). These are the only final-size
/// paths of a pane's content (principled audit, row paneHoldsContentInMotion, felt 1d): each is sized from the pane's
/// current rest size (``PaneMotionTargeting``) and ends at its landing (``PaneMotionSettling``).
@MainActor
public protocol PaneMotionHolding: NSView {
    /// Whether this view holds its content at a size other than its own area now.
    var holdsPaneMotionSize: Bool { get }
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

    /// The ``PaneMotionHolding`` views in this subtree (this view included) that hold a size now, each with how many
    /// holding views enclose it inside the subtree (0: none). A DEBUG check reads it (`PaneHostView`); never per frame.
    func paneMotionHolds() -> [(view: NSView, enclosingHolds: Int)] {
        var found: [(view: NSView, enclosingHolds: Int)] = []
        func visit(_ view: NSView, depth: Int) {
            let holds = (view as? PaneMotionHolding)?.holdsPaneMotionSize == true
            if holds { found.append((view: view, enclosingHolds: depth)) }
            for subview in view.subviews { visit(subview, depth: depth + (holds ? 1 : 0)) }
        }
        visit(self, depth: 0)
        return found
    }

    /// Tells every ``PaneMotionSettling`` view in this subtree (this view included) that its
    /// placement's spring landed.
    func notifyPaneMotionSettled() {
        if let settling = self as? PaneMotionSettling { settling.paneMotionDidSettle() }
        for subview in subviews { subview.notifyPaneMotionSettled() }
    }

    /// Tells every ``PanePlacementFollowing`` view in this subtree (this view included) that its pane host's
    /// place in the window is final.
    func notifyPanePlacementSettled() {
        if let following = self as? PanePlacementFollowing { following.panePlacementDidSettle() }
        for subview in subviews { subview.notifyPanePlacementSettled() }
    }
}

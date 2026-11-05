public import AppKit
public import CmuxNextDesign

/// FRAME OWNER REFACTOR S3: in a keyboard resize the terminal host is a container
/// that follows its pane in every frame: the pane's content area gives it its bounds each frame, so the terminal's own
/// ground, padding, scroller and overlays cover the whole pane and the window's shell never shows inside it. With
/// `motion.frameOwner.terminals` on (cmux-ad m6) the surface follows too: it takes the area it shows in, in every frame
/// (``followedSurfaceFrame(_:in:)``), and the PTY gets one grid per press. With the switch off only the surface's origin
/// moves: it keeps the final size the press asked for (``holdSurface(size:anchor:)``), else the size it had when the
/// hold began, fixed at the pane edge that does not move.
/// A person's divider or edge drag (`ScreenContentView+ResizeGesture`, cmux-ad m14) is told to the host, which outlives a
/// surface swap: the surface it shows follows the drag, and so does one installed during the drag (a replay's
/// `TerminalSession.swapSurface`: a surface joins its new host's drag, ``TerminalSurfaceView`` `viewWillMove(toSuperview:)`).
extension TerminalHostView: PaneResizeGestureFollowing {
    public func paneResizeGestureDidChange(active: Bool) {
        guard followsResizeGesture != active else { return }
        followsResizeGesture = active
        current?.followResizeGesture(active)
    }

    /// Out of its window no drag's end may reach it (its layout root can go first): a surface it shows later follows none.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { followsResizeGesture = false }
    }
}

extension TerminalHostView: PaneMotionHoldFollowing {
    public func followPaneMotion(_ hold: PaneMotionHold?, heldSize: CGSize?) {
        followedHold = hold.map { ($0, heldSize ?? bounds.size) }
        needsLayout = true
    }

    /// Shown during its pane's key hold (a tab switch to a parked terminal): it follows the pane from this frame.
    public override func viewDidUnhide() {
        super.viewDidUnhide()
        (superview as? PaneContentAreaView)?.followerDidShow()
    }

    /// The host size a pane spring's size change is measured against (``TerminalSurfaceView`` `restSize`): while it
    /// follows a hold, the size it had when the hold began (what the pane's rest size change is measured from), else its
    /// size now.
    var paneMotionBasisSize: CGSize { followedHold?.heldSize ?? bounds.size }

    /// The surface's frame while the host follows `followed`, and the edge a frame kept while its size waits rides (the
    /// frame owner's `place(_:anchor:)`): its held size on the hold's edges of the area it shows in
    /// (less a legacy scroller's strip). One exception to the still edge: a pane that grows down with its prompt in the
    /// lower half (`motionAnchor` answered `.bottom`) keeps the surface's bottom on its moving bottom edge, so the prompt on
    /// the final grid's last row stays in view; the surface is taller than the pane then, so it still covers it.
    ///
    /// With `motion.frameOwner.terminals` on (cmux-ad m6: pixels per frame, the program's size per press) the surface takes
    /// the area it shows in, in every frame, anchored top-left: the frame owner shows each size's frame with its bounds,
    /// or keeps the last frame (clipped, top-left) until it is drawn; the PTY still gets one grid per press (the final
    /// grid, ``TerminalSurfaceView`` `restAt`). Except the low prompt above (`restAt` held the surface on the bottom edge):
    /// it keeps only that hold's height, and only while the final grid is taller than the area: its bottom rides the
    /// area's bottom edge (the prompt stays in view) and it has the area's leading edge and width, so it never cuts the
    /// lines on a moving side edge and never leaves a band above the terminal (review of #35470 at c4d6c936c92, H1: a press
    /// on the other axis, or two grow presses and then a shrink, in one spring). The anchor is the frame's own: the bottom
    /// only while that hold is taller than the area, else the top, so a frame kept while a new size waits rides the edge its
    /// content does (review of #35914 at 03c050e893f: the area's frame on the bottom anchor cut the kept frame's top rows
    /// and moved its text with the bottom edge).
    func followedSurfaceFrame(_ followed: (hold: PaneMotionHold, heldSize: CGSize),
                              in area: CGRect) -> (frame: CGRect, anchor: PaneMotionAnchor) { // perf-hot: 4ms motion-frame
        let shown = CGRect(x: area.minX, y: area.minY, width: max(0, area.width - scrollerWidth), height: area.height)
        if TerminalDragTunables.framesOwnedByCommit.value {
            guard case .bottom? = surfaceHold?.anchor, let held = surfaceHold?.size, held.height > shown.height else {
                return (shown, .top)
            }
            // The host is not flipped: minY is the bottom edge.
            return (CGRect(x: shown.minX, y: shown.minY, width: shown.width, height: held.height), .bottom)
        }
        let size = surfaceHold?.size ?? surfaceSize(forHostSize: followed.heldSize)
        var hold = followed.hold
        if case .bottom? = surfaceHold?.anchor { hold.bottom = true }
        // With the switch off, `place` does not read the anchor.
        return (hold.producerFrame(size, in: shown), surfaceHold?.anchor ?? .top)
    }
}

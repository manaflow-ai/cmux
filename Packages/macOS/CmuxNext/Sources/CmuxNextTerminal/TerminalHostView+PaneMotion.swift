public import AppKit
public import CmuxNextDesign

/// FRAME OWNER REFACTOR S3: in a keyboard resize the terminal host is a container
/// that follows its pane in every frame: the pane's content area gives it its bounds each frame, so the terminal's own
/// ground, padding, scroller and overlays cover the whole pane and the window's shell never shows inside it. With
/// `motion.frameOwner.terminals` on (cmux-ad m6 and m14) the surface follows too: it takes the area it shows in, in every
/// frame (``followedSurfaceFrame(_:in:)``), and draws the grid that size fits; the PTY gets one grid per press. With the
/// switch off only the surface's origin moves: it keeps the final size the press asked for
/// (``holdSurface(size:anchor:)``), else the size it had when the hold began, fixed at the pane edge that does not move.
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

    /// Whether the surface takes the area it shows in, in every frame (cmux-ad m14): the host follows its pane through a
    /// key hold with `motion.frameOwner.terminals` on. The surface then holds no size (``TerminalSurfaceView`` `restAt`),
    /// and its reflow preview stays on, so each frame draws the grid its size fits with the cursor row in view.
    var surfaceFollowsArea: Bool { followedHold != nil && TerminalDragTunables.framesOwnedByCommit.value }

    /// The surface's frame while the host follows `followed`, and the edge a frame kept while its size waits rides (the
    /// frame owner's `place(_:anchor:)`).
    ///
    /// With `motion.frameOwner.terminals` on (cmux-ad m6 and m14: pixels at the pane's size in every frame, the program's
    /// size per press) the surface takes the area it shows in (less a legacy scroller's strip), anchored top-left, whatever
    /// hold it has (``surfaceFollowsArea``): the frame owner shows each size's frame with its bounds, or keeps the last
    /// frame (clipped, top-left) until it is drawn. Each frame draws the grid its size fits (the reflow preview), and the
    /// reflow keeps a low prompt's cursor row in view, so no hold keeps it there (F2: a bottom hold at the final size made
    /// the surface taller than its pane and cut its top rows). The PTY still gets one grid per press (the final grid,
    /// ``TerminalSurfaceView`` `restAt`).
    ///
    /// With the switch off: its held size on the hold's edges of the area. One exception to the still edge: a pane that
    /// grows down with its prompt in the lower half (`motionAnchor` answered `.bottom`) keeps the surface's bottom on its
    /// moving bottom edge, so the prompt on the final grid's last row stays in view; the surface is taller than the pane
    /// then, so it still covers it.
    func followedSurfaceFrame(_ followed: (hold: PaneMotionHold, heldSize: CGSize),
                              in area: CGRect) -> (frame: CGRect, anchor: PaneMotionAnchor) { // perf-hot: 4ms motion-frame
        let shown = CGRect(x: area.minX, y: area.minY, width: max(0, area.width - scrollerWidth), height: area.height)
        if surfaceFollowsArea { return (shown, .top) }
        let size = surfaceHold?.size ?? surfaceSize(forHostSize: followed.heldSize)
        var hold = followed.hold
        if case .bottom? = surfaceHold?.anchor { hold.bottom = true }
        // With the switch off, `place` does not read the anchor.
        return (hold.producerFrame(size, in: shown), surfaceHold?.anchor ?? .top)
    }
}

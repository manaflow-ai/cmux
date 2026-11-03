public import AppKit
public import CmuxNextDesign

/// FRAME OWNER REFACTOR S3 (`motion.frameOwner.contentPolicy`): in a keyboard resize the terminal host is a container
/// that follows its pane in every frame: the pane's content area gives it its bounds each frame, so the terminal's own
/// ground, padding, scroller and overlays cover the whole pane and the window's shell never shows inside it. Only the
/// surface (the producer: Ghostty draws it on its renderer thread) keeps its size: the final size the press asked for
/// (``holdSurface(size:anchor:)``, one grid per press), else the size it had when the hold began, fixed at the pane edge
/// that does not move. No grid and no reflow per frame: only the surface's origin moves.
extension TerminalHostView: PaneMotionHoldFollowing {
    public func followPaneMotion(_ hold: PaneMotionHold?, heldSize: CGSize?) {
        followedHold = hold.map { ($0, heldSize ?? bounds.size) }
        needsLayout = true
    }

    /// The host size a pane spring's size change is measured against (``TerminalSurfaceView`` `restSize`): while it
    /// follows a hold, the size it had when the hold began (what the pane's rest size change is measured from), else its
    /// size now.
    var paneMotionBasisSize: CGSize { followedHold?.heldSize ?? bounds.size }

    /// The surface's frame while the host follows `followed`: its held size on the hold's edges of the area it shows in
    /// (less a legacy scroller's strip).
    func followedSurfaceFrame(_ followed: (hold: PaneMotionHold, heldSize: CGSize), in area: CGRect) -> CGRect { // perf-hot: 4ms motion-frame
        let size = surfaceHold?.size ?? surfaceSize(forHostSize: followed.heldSize)
        let shown = CGRect(x: area.minX, y: area.minY, width: max(0, area.width - scrollerWidth), height: area.height)
        return followed.hold.producerFrame(size, in: shown)
    }
}

public import AppKit
public import CmuxNextDesign

/// FRAME OWNER REFACTOR S3 and cmux-ad m18: in a keyboard resize the terminal host is a container that follows its pane
/// in every frame: the pane's content area gives it its bounds each frame, so the terminal's own ground, padding,
/// scroller and overlays cover the whole pane and the window's shell never shows inside it. The surface follows too,
/// whatever `motion.frameOwner.terminals` says: it takes the area it shows in, in every frame
/// (``followedSurfaceFrame(in:)``), and draws the grid that size fits (Ghostty's reflow preview re-wraps the text at it);
/// the PTY gets the view's grid coalesced (``TerminalSurfaceView`` `updateSurfaceSize`). The switch only says who
/// presents each size's frame (the window's commit, or Ghostty's renderer). No key hold is left: m18 deleted it.
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

    /// Whether the surface takes the area it shows in, in every frame (cmux-ad m14 and m18): the host follows its pane
    /// through a key resize. The surface then holds no size (``TerminalSurfaceView`` `restAt`), and its reflow preview
    /// stays on, so each frame draws the grid its size fits with the cursor row in view.
    var surfaceFollowsArea: Bool { followedHold != nil }

    /// Whether the host is in a content area that holds for a key resize and will hand it the follow in the area's next
    /// layout pass (a parked tab shown mid-hold: its surface is shown, and joins, a pass before that).
    var joinsAreaKeyHold: Bool { followedHold == nil && (superview as? PaneContentAreaView)?.hold != nil }

    /// The surface's frame while the host follows its pane: the area it shows in (less a legacy scroller's strip),
    /// whatever hold it has. Each frame draws the grid its size fits (the reflow preview), and the reflow keeps a low
    /// prompt's cursor row in view, so no hold keeps it there (F2: a bottom hold at the final size made the surface taller
    /// than its pane and cut its top rows).
    func followedSurfaceFrame(in area: CGRect) -> CGRect { // perf-hot: 4ms motion-frame
        CGRect(x: area.minX, y: area.minY, width: max(0, area.width - scrollerWidth), height: area.height)
    }
}

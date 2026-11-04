public import AppKit
public import CmuxNextDesign

/// FRAME OWNER REFACTOR S3: in a keyboard resize the terminal host is a container that follows its pane in every frame:
/// the pane's content area gives it its bounds each frame, so the terminal's own ground, padding, scroller and overlays
/// cover the whole pane and the window's shell never shows inside it. The surface follows too (cmux-ad m6: pixels per
/// frame, the program's size per press): it takes the area it shows in, in every frame
/// (``TerminalHostView`` `surfaceFrame`), and the frame owner (S4) shows each size's frame with its bounds or keeps the
/// last frame, clipped and anchored top-left, until it is drawn; the PTY gets one grid per press, the final grid
/// (``TerminalSurfaceView`` `restAt`).
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
}

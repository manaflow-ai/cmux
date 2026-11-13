import AppKit
import CmuxNextDesign

extension FrameNoticeHold {
    /// A key resize's press put `screen` on its spring (``ScreenContentView/holdsContentForKeyResize``, the press's own
    /// layout in `update`): the displayed panes' views post no frame notice from the key's turn to the frame the spring
    /// lands in, as in a divider drag. Each frame then posts the notice of a reader alone (a Chromium page's host view:
    /// the fork's tracker runs its update once, not once more for each of the page's ancestors), and no notice of a pane
    /// view makes AppKit walk the titlebar drag shapes in the frame's commit. A press on a spring that already holds (a
    /// key repeat, a drag or a zoom in motion) keeps that hold: a release between two presses would post each moved
    /// view's notice once per press. A hidden or parked screen steps no frames, so it holds nothing.
    ///
    /// Every end of the key hold gives the notices back (the flag's `didSet`): the frame the spring lands in, a
    /// structural change, a press that does not spring, a landing at once (`settleMotion`) and a snap in the spring (a
    /// live window resize, a new backing scale: `reconcileAndScroll`, where no landing frame comes).
    func holdForKeyResize(_ screen: ScreenContentView) {
        guard screen.holdsContentForKeyResize, !isHolding, screen.window != nil, !screen.isHiddenOrHasHiddenAncestor,
              !screen.isParkedOrHasParkedAncestor else { return }
        hold(screen.displayedHosts)
    }
}

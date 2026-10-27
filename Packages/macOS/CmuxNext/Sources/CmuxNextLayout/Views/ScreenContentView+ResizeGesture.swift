import AppKit
import CmuxNextDesign

/// Where a screen's panes stand on a person's resize drag (``ScreenContentView/resizeGesture``).
enum PaneResizeGesturePhase: Equatable {
    /// No drag: the pane contents follow their frames.
    case idle
    /// A divider or edge moves under the pointer.
    case active
    /// Released; the layout the release makes has not reached this screen yet.
    case releasing
    /// The release's layout is here; its spring, if any, has not landed.
    case landing
}

/// A person's divider or edge drag, told to the pane contents that follow it their own way
/// (``PaneResizeGestureFollowing``: a Chromium page keeps its size until the pane's frame is final).
/// They hear `true` on the drag's first move (a click on a divider moves nothing and tells nothing)
/// and `false` once the release's layout landed, so a page lays out once, at the pane's final size,
/// not once per frame of the release's spring. No timer: the layout's display-frame ticks
/// (`step`, which the release requests) and the model sync carry it to the end, and a screen torn
/// down ends it at once.
extension ScreenContentView {
    func resizeGestureMoved() {
        if resizeGesture == .idle {
            for host in displayedHosts { host.content.notifyPaneResizeGesture(active: true) }
        }
        resizeGesture = .active
    }

    /// The pointer let go (or the drag was cancelled): the end waits for the release's layout and its landing.
    func resizeGestureReleased() {
        guard resizeGesture == .active else { return }
        resizeGesture = .releasing
        context.requestFrames()
    }

    /// `LayoutRootView.sync` applied the model with its gesture flag: once it is off, the release's
    /// layout (and the spring it starts) is in this screen.
    func resizeGestureModelSynced(gestureActive: Bool) {
        guard resizeGesture == .releasing, !gestureActive else { return }
        resizeGesture = .landing
        finishResizeGestureIfLanded()
    }

    /// Every display frame of this screen (`step`): the end comes when no pane or divider moves.
    func finishResizeGestureIfLanded() {
        // A tick before the sync: the model's flag is already off, so the release's layout is applied
        // this turn or was refused; either way the frames are final once nothing moves.
        if resizeGesture == .releasing, !context.model.isGestureActive { resizeGesture = .landing }
        guard resizeGesture == .landing, !hasMotion else { return }
        finishResizeGesture()
    }

    /// Tells the pane contents the drag is over, now (also when the screen goes away).
    func finishResizeGesture() {
        guard resizeGesture != .idle else { return }
        resizeGesture = .idle
        for host in displayedHosts { host.content.notifyPaneResizeGesture(active: false) }
    }
}

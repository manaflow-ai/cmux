import AppKit
import CmuxNextDesign

/// Pacing and the end of the sidebar's width animation. Every frame of the
/// animation moves the content edge, so both costs beside it are kept off the
/// frame: hover refreshes run on a deadline rather than per frame, and the
/// motion ends even if AppKit loses the animation's completion.
extension SidebarContainerView {
    func refreshHover() {
        hoverRefresh.cancel()
        PointerHover.refresh(in: window)
    }

    /// Ends the width motion on its own if the animation's completion never
    /// runs (`widthMotionWatchdog`). The flag's `didSet` cancels this as soon
    /// as the completion, `snap()` or a drag ends the motion the usual way, so
    /// in the normal case this never fires.
    func armWidthMotionWatchdog(_ token: MotionSpring) {
        let due = Duration.seconds(Motion.sidebar.duration(token)) + Self.widthMotionSlack
        widthMotionWatchdog.schedule(after: due) { @MainActor [weak self] in
            guard let self, self.isWidthAnimating else { return }
            self.isWidthAnimating = false
            self.refreshHover()
        }
    }
}

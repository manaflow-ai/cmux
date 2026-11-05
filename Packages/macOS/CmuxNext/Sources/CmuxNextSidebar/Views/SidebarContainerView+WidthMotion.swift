import AppKit
import CmuxNextDesign

/// Pacing and the end of the sidebar's width animation. Every frame of the
/// animation moves the content edge, so both costs beside it are kept off the
/// frame: hover refreshes run on a deadline rather than per frame, and the
/// motion ends even if its completion is lost.
extension SidebarContainerView {
    /// Where one width motion goes from and to: the width and the clip's reach into the gutter ride one progress.
    struct WidthLeg {
        var width: (from: CGFloat, to: CGFloat)
        var reach: (from: CGFloat, to: CGFloat)
        var edge: NSLayoutConstraint
    }

    /// Slides to `width` on the window's motion clock (`TimedProgress`), the clock the panes' springs step on, so every
    /// frame of the slide and the panes beside it land in the same frame and commit (Leo 2026-11-05: "everything moves
    /// as one"). The token's duration and the timed curve are the ones the AppKit animation had; a slide under way
    /// turns around from the width on screen. No animation (Reduce Motion, the sidebar's motion off): lands now.
    func startWidthMotion(to width: CGFloat, reach: CGFloat, collapsed: Bool, token: MotionSpring,
                          completion: @escaping @MainActor () -> Void) {
        let (edge, target) = clipReachEdge(reach, collapsed: collapsed)
        let (fromWidth, fromReach) = shownWidthAndReach(edge)
        widthLeg = WidthLeg(width: (fromWidth, width), reach: (fromReach, target), edge: edge)
        // The leg starts on screen: this frame's layout pass shows the turn, not the old slide's step.
        (widthConstraint.constant, edge.constant) = (fromWidth, fromReach)
        let duration = Motion.sidebar.canAnimate(in: self) ? Motion.sidebar.duration(token) : 0
        widthMotion.run(duration: duration, in: self, trace: "sidebar.width", completion: completion)
    }

    /// Where a new slide starts: the width on screen and the reach at the same point of the slide under way. A slide
    /// stepped earlier in this frame has moved the constraints past the laid-out frame, which is what shows until the
    /// window's layout pass; starting from them, or leaving them there, would carry the old slide one frame further
    /// before it turns around.
    private func shownWidthAndReach(_ edge: NSLayoutConstraint) -> (CGFloat, CGFloat) {
        guard widthMotion.isRunning, let leg = widthLeg, leg.edge === edge, leg.width.to != leg.width.from else {
            return (widthConstraint.constant, edge.constant)
        }
        let shown = frame.width
        let p = min(max((shown - leg.width.from) / (leg.width.to - leg.width.from), 0), 1)
        return (shown, leg.reach.from + (leg.reach.to - leg.reach.from) * p)
    }

    /// One frame of the slide: both constraints at `progress` of their leg; the window's layout pass resizes the
    /// content beside the sidebar in this frame.
    func stepWidth(_ progress: Double) {
        guard let leg = widthLeg else { return }
        let p = CGFloat(progress)
        widthConstraint.constant = leg.width.from + (leg.width.to - leg.width.from) * p
        leg.edge.constant = leg.reach.from + (leg.reach.to - leg.reach.from) * p
        if progress >= 1 { widthLeg = nil }
    }

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

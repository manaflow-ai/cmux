public import AppKit

/// Drives sidebar auto-scrolling while a drag hovers near the scroll view's top
/// or bottom edge using one viewport-relative plan and one constrained scroll
/// path.
@MainActor
public final class SidebarDragAutoScrollController {
    private weak var scrollView: NSScrollView?
    private var timer: Timer?
    private var activePlan: SidebarAutoScrollPlan?

    public init() {}

    public func attach(scrollView: NSScrollView?) {
        self.scrollView = scrollView
    }

    public func updateFromDragLocation() {
        guard let scrollView else {
            stop()
            return
        }
        guard let plan = plan(for: scrollView) else {
            stop()
            return
        }
        activePlan = plan
        startTimerIfNeeded()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        activePlan = nil
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func tick() {
        guard NSEvent.pressedMouseButtons != 0 else {
            stop()
            return
        }
        guard let scrollView else {
            stop()
            return
        }

        activePlan = self.plan(for: scrollView)
        guard let plan = activePlan else {
            stop()
            return
        }
        if !apply(plan: plan, to: scrollView) {
            stop()
        }
    }

    private func distancesToEdges(
        mousePoint: CGPoint,
        viewportBounds: CGRect,
        isFlipped: Bool
    ) -> (top: CGFloat, bottom: CGFloat) {
        if isFlipped {
            return (
                top: mousePoint.y - viewportBounds.minY,
                bottom: viewportBounds.maxY - mousePoint.y
            )
        }
        return (
            top: viewportBounds.maxY - mousePoint.y,
            bottom: mousePoint.y - viewportBounds.minY
        )
    }

    /// Computes a drag plan against the clip view's current visible bounds.
    func planForMousePoint(_ mousePoint: CGPoint, in clipView: NSClipView) -> SidebarAutoScrollPlan? {
        let viewportBounds = clipView.bounds
        guard viewportBounds.height > 0 else { return nil }

        let distances = distancesToEdges(
            mousePoint: mousePoint,
            viewportBounds: viewportBounds,
            isFlipped: clipView.isFlipped
        )
        return SidebarDragAutoScrollPlanner(distanceToTop: distances.top, distanceToBottom: distances.bottom).plan
    }

    private func mousePoint(in clipView: NSClipView) -> CGPoint {
        let mouseInWindow = clipView.window?.convertPoint(fromScreen: NSEvent.mouseLocation) ?? .zero
        return clipView.convert(mouseInWindow, from: nil)
    }

    private func currentPlan(for scrollView: NSScrollView) -> SidebarAutoScrollPlan? {
        let clipView = scrollView.contentView
        let mouse = mousePoint(in: clipView)
        return planForMousePoint(mouse, in: clipView)
    }

    private func plan(for scrollView: NSScrollView) -> SidebarAutoScrollPlan? {
        currentPlan(for: scrollView)
    }

    private func apply(plan: SidebarAutoScrollPlan, to scrollView: NSScrollView) -> Bool {
        guard scrollView.documentView != nil else { return false }
        let clipView = scrollView.contentView
        let directionMultiplier: CGFloat = (plan.direction == .down) ? 1 : -1
        let flippedMultiplier: CGFloat = clipView.isFlipped ? 1 : -1
        let delta = directionMultiplier * flippedMultiplier * plan.pointsPerTick
        let currentBounds = clipView.bounds
        let proposedBounds = CGRect(
            x: currentBounds.origin.x,
            y: currentBounds.origin.y + delta,
            width: currentBounds.width,
            height: currentBounds.height
        )
        let constrainedBounds = clipView.constrainBoundsRect(proposedBounds)
        guard abs(constrainedBounds.origin.y - currentBounds.origin.y) > 0.01 else { return false }

        clipView.scroll(to: constrainedBounds.origin)
        scrollView.reflectScrolledClipView(clipView)
        return true
    }
}

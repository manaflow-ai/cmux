public import AppKit
public import Combine

/// Drives sidebar auto-scrolling while a drag hovers near the scroll view's top
/// or bottom edge. Prefers AppKit's native `NSClipView.autoscroll(with:)` when a
/// drag event is available and falls back to a manual per-tick scroll computed
/// from `SidebarDragAutoScrollPlanner`.
@MainActor
public final class SidebarDragAutoScrollController: ObservableObject {
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
        // Planner-driven scrolling only. The former autoscroll(with:) fast
        // path read NSApp.currentEvent, which inside a timer tick is whatever
        // event happened to be processed last — a stale position basis that
        // produced erratic speeds; and it had no content clamp, so parking at
        // an edge rubber-banded elastically on every tick.
        guard apply(plan: plan, to: scrollView) else {
            stop()
            return
        }
    }

    private func distancesToEdges(mousePoint: CGPoint, viewportHeight: CGFloat, isFlipped: Bool) -> (top: CGFloat, bottom: CGFloat) {
        if isFlipped {
            return (top: mousePoint.y, bottom: viewportHeight - mousePoint.y)
        }
        return (top: viewportHeight - mousePoint.y, bottom: mousePoint.y)
    }

    func planForMousePoint(_ mousePoint: CGPoint, in clipView: NSClipView) -> SidebarAutoScrollPlan? {
        let viewportHeight = clipView.bounds.height
        guard viewportHeight > 0 else { return nil }

        // Points converted into the clip view are in DOCUMENT coordinates,
        // whose origin is the scroll offset. Edge distances must be viewport
        // relative: without removing bounds.origin, any pointer position
        // scrolled more than one viewport height deep measures as "past the
        // bottom edge", which planned max-speed downward scrolling from
        // anywhere in the list (the runaway-scroll report).
        let viewportPoint = CGPoint(
            x: mousePoint.x - clipView.bounds.origin.x,
            y: mousePoint.y - clipView.bounds.origin.y
        )
        let distances = distancesToEdges(
            mousePoint: viewportPoint,
            viewportHeight: viewportHeight,
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
        guard let documentView = scrollView.documentView else { return false }
        let clipView = scrollView.contentView

        let directionMultiplier: CGFloat = (plan.direction == .down) ? 1 : -1
        let flippedMultiplier: CGFloat = documentView.isFlipped ? 1 : -1
        let delta = directionMultiplier * flippedMultiplier * plan.pointsPerTick
        let currentY = clipView.bounds.origin.y
        // constrainBoundsRect is the boundary authority: unlike a manual
        // [0, contentHeight] clamp it honors the scroll view's content
        // insets, so the list scrolls all the way into the inset margins at
        // the top and bottom instead of stopping one inset short.
        var target = clipView.bounds
        target.origin.y = currentY + delta
        let constrainedY = clipView.constrainBoundsRect(target).origin.y
        guard abs(constrainedY - currentY) > 0.01 else { return false }

        clipView.scroll(to: CGPoint(x: clipView.bounds.origin.x, y: constrainedY))
        scrollView.reflectScrolledClipView(clipView)
        return true
    }
}

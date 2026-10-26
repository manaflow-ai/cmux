import AppKit

/// One sidebar view's space paging from scroll events: a two-finger horizontal trackpad
/// swipe (`ProfileSwipeTracker`) and a mouse wheel roll (`SpaceWheelPager`). The input tap
/// feeds it before AppKit dispatches the event, so the view's `scrollWheel` only asks whether
/// its own scrolling skips the event. A vertical gesture then goes to `NSScrollView` untouched,
/// which lets the list take responsive scrolling (p03-110), where AppKit tracks the gesture
/// itself and stops calling `scrollWheel` after its first event.
///
/// A gesture is hit-tested at its start and stays latched to the view until it ends, as
/// Chrome latches a wheel scroll sequence to its first target
/// (content/browser/renderer_host/render_widget_host_input_event_router.cc,
/// RouteMouseWheelEvent and wheel_target_).
final class SidebarSwipeInput {
    /// Called with -1 (previous) or +1 (next) once per qualifying swipe.
    var onHorizontalSwipe: ((Int) -> Void)?
    /// A horizontal gesture 1:1 (R99): its phase, finger dx and time. When set, it replaces
    /// the one-step swipe.
    var onHorizontalScroll: ((ProfileSwipeTracker.Phase, CGFloat, TimeInterval) -> Void)?
    /// A mouse wheel notch paged the spaces: -1 (previous) or +1 (next).
    var onWheelPage: ((Int) -> Void)?

    /// A vertical mouse wheel pages too (over the dots, where nothing scrolls vertically).
    private let pagesVertically: Bool
    private var tracker = ProfileSwipeTracker()
    private var wheel = SpaceWheelPager()
    private var paging = false
    /// The trackpad gesture in progress began over the view.
    private var latched = false
    /// The last event observed, and whether the view's own scrolling skips it.
    private weak var observed: NSEvent?
    private var skipsObserved = false
    private var subscription: AnyObject?

    init(pagesVertically: Bool) { self.pagesVertically = pagesVertically }

    /// Observes `view`'s window through `tap`; no tap or no window drops the subscription.
    func subscribe(_ tap: (any SidebarScrollTap)?, view: NSView) {
        subscription = nil
        guard let tap, let window = view.window else { return }
        subscription = tap.observeScrolls(
            in: window,
            where: { [weak self, weak view] event in
                guard let self, let view else { return false }
                return self.claims(event, hit: { Self.hits(view, event) })
            },
            handler: { [weak self] event in self?.observe(event) })
    }

    /// The tap's predicate: whether `event` belongs to this view. A gesture's first event and
    /// a phaseless wheel notch are hit-tested (`hit`); the rest of a gesture follows its start.
    func claims(_ event: NSEvent, hit: () -> Bool) -> Bool {
        if event.phase.contains(.began) {
            latched = hit()
            return latched
        }
        if !event.phase.isEmpty || !event.momentumPhase.isEmpty { return latched }
        return hit()
    }

    /// The tap's handler: feeds the tracker or the wheel pager, then calls the paging callbacks.
    func observe(_ event: NSEvent) {
        observed = event
        skipsObserved = feed(event)
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { latched = false }
    }

    /// From the view's `scrollWheel`: whether its own scrolling skips `event`. An event the tap
    /// did not deliver (no tap wired, or AppKit routed it here past the hit test) is observed now.
    func skipsScrolling(_ event: NSEvent) -> Bool {
        if observed !== event { observe(event) }
        return skipsObserved
    }

    /// True: the view's scrolling skips the event.
    private func feed(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas, let phase = Self.phase(of: event) else {
            guard let onWheelPage, !event.hasPreciseScrollingDeltas else { return false }
            switch wheel.feed(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, time: event.timestamp,
                              pagesVertically: pagesVertically) {
            case .pass: return false
            case .hold: return true
            case .page(let step):
                onWheelPage(step)
                return true
            }
        }
        let step = tracker.feed(deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY), phase: phase)
        if let onHorizontalScroll {
            if phase == .ended || phase == .momentum {
                if paging, phase == .ended { onHorizontalScroll(.ended, 0, event.timestamp) }
                paging = false
            } else if tracker.isHorizontal {
                onHorizontalScroll(paging ? .changed : .began, event.scrollingDeltaX, event.timestamp)
                paging = true
            }
        } else if let step {
            onHorizontalSwipe?(step)
        }
        // A horizontal gesture never scrolls: the list cannot scroll sideways, and elastic
        // bounce would jitter.
        return tracker.isHorizontal
    }

    /// Whether AppKit sends `event` to `view` or a view inside it: the window's hit test at
    /// the event's location, as `-[NSWindow sendEvent:]` routes a scroll.
    static func hits(_ view: NSView, _ event: NSEvent) -> Bool {
        guard let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return false }
        let point: NSPoint
        if let eventWindow = event.window {
            guard eventWindow === window else { return false }
            point = event.locationInWindow
        } else {
            point = window.convertPoint(fromScreen: event.locationInWindow)
        }
        let frameView = window.contentView?.superview ?? window.contentView
        return frameView?.hitTest(point)?.isDescendant(of: view) ?? false
    }

    private static func phase(of event: NSEvent) -> ProfileSwipeTracker.Phase? {
        if !event.momentumPhase.isEmpty { return .momentum }
        if event.phase.contains(.began) { return .began }
        if event.phase.contains(.changed) { return .changed }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { return .ended }
        return nil
    }
}

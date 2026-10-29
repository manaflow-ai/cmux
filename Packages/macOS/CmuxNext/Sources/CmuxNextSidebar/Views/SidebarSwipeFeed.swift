import AppKit
import CmuxNextInput

/// A sidebar view's space paging from the app's input tap: the two-finger horizontal
/// trackpad swipe (`ProfileSwipeTracker`, or 1:1 through `onHorizontalScroll`) and the mouse wheel page
/// (`SpaceWheelPager`) hear every scroll of the view's window as a passing intercept at
/// ``InputEventTap/InterceptOrder/standard``, before AppKit dispatches it. An intercept that comes first
/// and consumes the scroll (a hover card's own scroll at `popup`, the layout's at `layout`) keeps it from
/// the paging, so one input never both scrolls a card and pages the spaces. The view's
/// `scrollWheel(with:)` only asks ``takes(_:)`` whether to keep an event from scrolling; it feeds nothing.
/// So the paging still hears a gesture that AppKit's responsive scrolling tracks without calling
/// `scrollWheel(with:)` for each event.
///
/// A trackpad gesture latches at its first event: it is the view's when that event hits the view, and
/// every later event of the gesture, its momentum too, goes with it wherever the pointer is then. A
/// wheel notch has no gesture: each one is hit tested. Chrome latches a wheel scroll sequence to the
/// target its phase-began event hit the same way (content/browser/renderer_host/
/// render_widget_host_input_event_router.cc, RouteMouseWheelEvent's `wheel_target_`, and
/// content/browser/renderer_host/input/mouse_wheel_phase_handler.cc).
@MainActor final class SidebarSwipeFeed {
    /// Called with -1 (previous) or +1 (next) once per qualifying swipe.
    var onHorizontalSwipe: ((Int) -> Void)?
    /// A horizontal gesture 1:1 (R99): its phase, finger dx and time. When set, it replaces the one-step swipe.
    var onHorizontalScroll: ((ProfileSwipeTracker.Phase, CGFloat, TimeInterval) -> Void)?
    /// A mouse wheel notch paged the spaces: -1 (previous) or +1 (next).
    var onWheelPage: ((Int) -> Void)?

    /// A vertical wheel pages too (the space bar, where nothing scrolls); else only a sideways one does.
    private let pagesVertically: Bool
    private weak var view: NSView?
    private var tracker = ProfileSwipeTracker()
    private var wheel = SpaceWheelPager()
    /// A 1:1 gesture is under way (`onHorizontalScroll` had its began).
    private var paging = false
    /// The current trackpad gesture began over the view.
    private var latched = false
    /// The last event fed and whether the paging took it (``takes(_:)``), by timestamp: no event is retained.
    private var decided: (timestamp: TimeInterval, took: Bool)?
    private var subscription: InputSubscription?
    private weak var subscribedTap: InputEventTap?
    private weak var subscribedWindow: NSWindow?

    init(view: NSView, pagesVertically: Bool) {
        self.view = view
        self.pagesVertically = pagesVertically
    }

    /// Whether anything pages from this view: the tap calls the feed only then.
    private var listens: Bool { onHorizontalSwipe != nil || onHorizontalScroll != nil || onWheelPage != nil }

    /// Hears the scrolls on `tap` while the view is in `window`, and pages for `window`'s; either nil hears
    /// none. Called when the view moves to a window
    /// and when its tap changes; the same pair keeps the subscription it has.
    func follow(tap: InputEventTap?, window: NSWindow?) {
        guard tap !== subscribedTap || window !== subscribedWindow else { return }
        subscription?.cancel()
        subscription = nil
        subscribedTap = tap
        subscribedWindow = window
        latched = false
        decided = nil
        guard let tap, window != nil else { return }
        // Every window's scrolls: the tap's window scope never matches a synthesized scroll that AppKit left
        // windowless. ``hits(_:)`` keeps only the view's window's. The intercept passes every scroll: the view's
        // `scrollWheel(with:)` keeps what the paging took (``takes(_:)``), as the responder AppKit routes it to.
        subscription = tap.subscribe(class: .scroll, phase: .intercept(order: .standard),
                                     while: { [weak self] in self?.listens ?? false }) { [weak self] event in
            guard let self else { return .pass }
            receive(event) { self.hits(event) }
            return .pass
        }
    }

    /// Whether the view's `scrollWheel(with:)` keeps `event` from scrolling: the paging took it (a
    /// horizontal gesture, or a wheel notch that paged or belongs to a roll that paged). An event the tap
    /// did not feed (a window with no tap) scrolls.
    func takes(_ event: NSEvent) -> Bool {
        guard let decided, decided.timestamp == event.timestamp else { return false }
        return decided.took
    }

    /// One scroll the tap delivered. `over` hit tests it; it is asked only for a gesture's first event
    /// and for a wheel notch.
    func receive(_ event: NSEvent, over: () -> Bool) {
        guard event.type == .scrollWheel else { return }
        decided = (event.timestamp, take(event, over: over))
    }

    /// The paging's work for one scroll; true when it took the event.
    private func take(_ event: NSEvent, over: () -> Bool) -> Bool {
        guard event.hasPreciseScrollingDeltas, let phase = Self.phase(of: event) else {
            guard let onWheelPage, !event.hasPreciseScrollingDeltas, over() else { return false }
            switch wheel.feed(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, time: event.timestamp,
                              pagesVertically: pagesVertically) {
            case .pass: return false
            case .hold: return true
            case .page(let step):
                onWheelPage(step)
                return true
            }
        }
        if phase == .began { latched = over() }
        guard latched else { return false }
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
        // A horizontal gesture never scrolls: the list cannot scroll sideways, and its elastic bounce would jitter.
        return tracker.isHorizontal
    }

    /// Whether `event` hits the view the way AppKit routes a scroll: in the view's window, on the view
    /// or a view inside it that no other scroll view holds. A point outside the view's bounds is
    /// rejected before the hit test.
    private func hits(_ event: NSEvent) -> Bool {
        guard let view, let window = view.window, let point = Self.location(of: event, in: window),
              view.bounds.contains(view.convert(point, from: nil)),
              let root = window.contentView?.superview ?? window.contentView,
              let hit = root.hitTest(point) else { return false }
        return Self.routes(hit: hit, to: view)
    }

    /// `event`'s point in `window`'s coordinates when the event goes to `window`; nil when it goes elsewhere.
    /// A scroll that `NSEvent(cgEvent:)` left windowless (`debug.mouse`, `debug.sidebar_wheel`) names its
    /// window in its Quartz window field, and its location is on the screen (`NSEvent.locationInWindow`).
    static func location(of event: NSEvent, in window: NSWindow) -> NSPoint? {
        let quartzWindow = event.window == nil
            ? event.cgEvent.map { Int($0.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)) } : nil
        return location(eventWindow: event.window, quartzWindowNumber: quartzWindow, point: event.locationInWindow, in: window)
    }

    /// ``location(of:in:)`` from the event's parts: its window, the window number its Quartz event names, and
    /// its `locationInWindow` (screen coordinates when it has no window).
    static func location(eventWindow: NSWindow?, quartzWindowNumber: Int?, point: NSPoint, in window: NSWindow) -> NSPoint? {
        if let eventWindow { return eventWindow === window ? point : nil }
        guard window.windowNumber > 0, quartzWindowNumber == window.windowNumber else { return nil }
        return window.convertPoint(fromScreen: point)
    }

    /// Whether a scroll that hit `hit` reaches `view`: `hit` is `view` or inside it, and no scroll view
    /// between them takes it first.
    static func routes(hit: NSView, to view: NSView) -> Bool {
        var current: NSView? = hit
        while let candidate = current {
            if candidate === view { return true }
            if candidate is NSScrollView { return false }
            current = candidate.superview
        }
        return false
    }

    static func phase(of event: NSEvent) -> ProfileSwipeTracker.Phase? {
        if !event.momentumPhase.isEmpty { return .momentum }
        if event.phase.contains(.began) { return .began }
        if event.phase.contains(.changed) { return .changed }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { return .ended }
        return nil
    }
}

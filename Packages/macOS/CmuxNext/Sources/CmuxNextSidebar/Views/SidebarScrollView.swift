import AppKit

/// The sidebar list's scroll view. A two-finger horizontal trackpad swipe
/// over it switches profiles instead of scrolling; vertical scrolling
/// is unchanged. One switch per gesture (`ProfileSwipeTracker`). A sideways
/// mouse wheel (tilt, or Shift) pages the spaces too, one per roll
/// (`SpaceWheelPager`); up or down always scrolls the list.
///
/// This class scrolls on the main thread: every event reaches the override, which pages a horizontal
/// gesture and hands the rest to `super` event by event. ``ResponsiveSidebarScrollView`` (feature
/// `responsiveScrolling`) scrolls on AppKit's scrolling thread instead.
class SidebarScrollView: NSScrollView {
    /// Called with -1 (previous) or +1 (next) once per qualifying swipe.
    var onHorizontalSwipe: ((Int) -> Void)?
    /// A horizontal gesture 1:1 (R99): its phase, finger dx and time. When
    /// set, it replaces the one-step swipe.
    var onHorizontalScroll: ((ProfileSwipeTracker.Phase, CGFloat, TimeInterval) -> Void)?
    /// A mouse wheel notch paged the spaces: -1 (previous) or +1 (next).
    var onWheelPage: ((Int) -> Void)?
    private var tracker = ProfileSwipeTracker()
    private var wheel = SpaceWheelPager()
    private var latch = ScrollAxisLatch<NSEvent>()
    private var paging = false

    /// The override reads every event of a gesture, so AppKit must not take a gesture over.
    override class var isCompatibleWithResponsiveScrolling: Bool { false }

    override func scrollWheel(with event: NSEvent) { // local-monitor-allow: the space swipe reads every scroll event's phase, delta and time in order; the rest goes to super
        guard event.hasPreciseScrollingDeltas else {
            if let onWheelPage {
                switch wheel.feed(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, time: event.timestamp, pagesVertically: false) {
                case .pass: break
                case .hold: return
                case .page(let step): return onWheelPage(step)
                }
            }
            super.scrollWheel(with: event)
            return
        }
        let phase = Self.phase(of: event)
        if Self.isCompatibleWithResponsiveScrolling { return railed(event, phase: phase) }
        guard let phase else { return super.scrollWheel(with: event) }
        let step = tracker.feed(deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY), phase: phase)
        page(step: step, phase: phase, horizontal: tracker.isHorizontal, event: event)
        // A horizontal gesture never scrolls the list; the list cannot
        // scroll horizontally anyway, and elastic bounce would jitter.
        if !tracker.isHorizontal { super.scrollWheel(with: event) }
    }

    /// AppKit sends `scrollWheel` only until a gesture reaches `super`, then tracks the rest itself. So a
    /// gesture reaches `super` only once ``ScrollAxisLatch`` has railed it vertical, its held events first;
    /// a horizontal one never does and stays here for paging.
    private func railed(_ event: NSEvent, phase: ProfileSwipeTracker.Phase?) {
        let route = latch.route(event, phase: phase, touchDown: event.phase.contains(.mayBegin),
                                deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY))
        if let phase {
            let step = tracker.feed(deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY), phase: phase)
            var horizontal = false
            if case .horizontal = route { horizontal = true }
            page(step: step, phase: phase, horizontal: horizontal, event: event)
        }
        if case .list(let events) = route {
            for listEvent in events { super.scrollWheel(with: listEvent) }
        }
    }

    /// Pages the spaces for one event of a horizontal gesture; `step` is the swipe tracker's for it.
    private func page(step: Int?, phase: ProfileSwipeTracker.Phase, horizontal: Bool, event: NSEvent) {
        if let onHorizontalScroll {
            if phase == .ended || phase == .momentum {
                if paging, phase == .ended { onHorizontalScroll(.ended, 0, event.timestamp) }
                paging = false
            } else if horizontal {
                onHorizontalScroll(paging ? .changed : .began, event.scrollingDeltaX, event.timestamp)
                paging = true
            }
        } else if let step, horizontal {
            onHorizontalSwipe?(step)
        }
    }

    private static func phase(of event: NSEvent) -> ProfileSwipeTracker.Phase? {
        if !event.momentumPhase.isEmpty { return .momentum }
        if event.phase.contains(.began) { return .began }
        if event.phase.contains(.changed) { return .changed }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { return .ended }
        return nil
    }
}

/// The sidebar list on AppKit's responsive scrolling (feature `responsiveScrolling`, p03-rendering-110):
/// the list scrolls on AppKit's scrolling thread, as Chrome scrolls on its compositor thread
/// (cc/input/input_handler.cc), so a main-thread stall does not stop a scroll or its momentum.
final class ResponsiveSidebarScrollView: SidebarScrollView {
    /// The override diverts only horizontal gestures and hands every vertical one to `super` whole.
    override class var isCompatibleWithResponsiveScrolling: Bool { true }
}

/// The axis of one trackpad gesture, decided once and kept through its momentum. Chrome rails each wheel
/// event from a decayed sum of the sequence's deltas
/// (content/browser/renderer_host/input/mouse_wheel_rails_filter_mac.mm, `MouseWheelRailsFilterMac`);
/// AppKit keeps a gesture once `super` has seen it, so here the decision is final and waits until the
/// gesture leans clearly one way. Until then its events are held: a vertical decision hands them to the
/// list in order with the current one, a horizontal one drops them.
nonisolated struct ScrollAxisLatch<Event> {
    /// Where one event goes.
    enum Route {
        /// Not decided yet: the event is held.
        case hold
        /// The list scrolls these (`super`), in order: the held events of a gesture just railed vertical,
        /// then the current one.
        case list([Event])
        /// A horizontal gesture: paging only.
        case horizontal
    }

    enum Axis: Equatable, Sendable { case undecided, vertical, horizontal }

    /// Travel that decides a gesture leaning clearly one way (twice the other axis), in points:
    /// ``ProfileSwipeTracker/isHorizontal``'s 4.
    static var slop: Double { 4 }
    /// Travel that decides a gesture leaning neither way: vertical, as the main-thread path scrolls it.
    static var window: Double { 16 }

    private(set) var axis = Axis.undecided
    private var dx = 0.0
    private var dy = 0.0
    /// A began or changed event of the gesture is held (not only its touch-down).
    private var moved = false
    private var held: [Event] = []

    /// The axis that `dx`, `dy` of travel so far decide, if any.
    static func lean(dx: Double, dy: Double) -> Axis {
        let x = abs(dx), y = abs(dy)
        if x > y * 2, x > slop { return .horizontal }
        if y > x * 2, y >= slop { return .vertical }
        return max(x, y) >= window ? .vertical : .undecided
    }

    /// Routes one precise scroll event. `phase` nil is an event outside a gesture phase; `touchDown` marks
    /// fingers landing (`mayBegin`), which starts a new gesture, as `began` does after a decided or moved one.
    mutating func route(_ event: Event, phase: ProfileSwipeTracker.Phase?, touchDown: Bool,
                        deltaX: Double, deltaY: Double) -> Route {
        if touchDown || (phase == .began && (axis != .undecided || moved)) { reset() }
        switch phase {
        case nil:
            // A stationary event inside an undecided gesture waits with it; any other goes to the list.
            guard touchDown || !held.isEmpty else { return .list([event]) }
            held.append(event)
            return .hold
        case .began, .changed:
            guard axis == .undecided else { return routeDecided(event) }
            held.append(event)
            moved = true
            dx += deltaX
            dy += deltaY
            let leaning = Self.lean(dx: dx, dy: dy)
            return leaning == .undecided ? .hold : decide(leaning)
        case .ended:
            guard axis == .undecided else { return routeDecided(event) }
            // Too short to show an axis: a small scroll is still the list's, as it was before the latch.
            held.append(event)
            return decide(.vertical)
        case .momentum:
            return axis == .undecided ? .list([event]) : routeDecided(event)
        }
    }

    private mutating func reset() {
        axis = .undecided
        dx = 0
        dy = 0
        moved = false
        held = []
    }

    private mutating func decide(_ decided: Axis) -> Route {
        axis = decided
        let events = held
        held = []
        return decided == .horizontal ? .horizontal : .list(events)
    }

    private func routeDecided(_ event: Event) -> Route {
        axis == .horizontal ? .horizontal : .list([event])
    }
}

extension ScrollAxisLatch.Route: Equatable where Event: Equatable {}

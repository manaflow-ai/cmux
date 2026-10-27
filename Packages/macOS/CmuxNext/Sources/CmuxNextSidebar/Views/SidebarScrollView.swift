import AppKit

/// The sidebar list's scroll view. A two-finger horizontal trackpad swipe
/// over it switches profiles instead of scrolling; vertical scrolling
/// is unchanged. One switch per gesture (`ProfileSwipeTracker`). A sideways
/// mouse wheel (tilt, or Shift) pages the spaces too, one per roll
/// (`SpaceWheelPager`); up or down always scrolls the list.
///
/// It keeps AppKit's responsive scrolling (p03-rendering-110): the list scrolls off the main thread, as
/// Chrome scrolls on its compositor thread (cc/input/input_handler.cc), so a main-thread stall does not
/// stop a scroll or its momentum. With it, AppKit sends `scrollWheel` only until a gesture reaches
/// `super`, then tracks the rest itself. So a gesture reaches `super` only once ``ScrollAxisLatch`` has
/// railed it vertical, with its held events from `mayBegin` on first; a horizontal one never does and
/// stays here for paging.
final class SidebarScrollView: NSScrollView {
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

    /// The override only diverts horizontal gestures and hands every vertical one to `super` whole,
    /// from `mayBegin` on.
    override class var isCompatibleWithResponsiveScrolling: Bool { true }

    override func scrollWheel(with event: NSEvent) {
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
        let route = latch.route(event, phase: phase, touchDown: event.phase.contains(.mayBegin),
                                deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY))
        var horizontal = false
        if case .horizontal = route { horizontal = true }
        if let phase { page(phase: phase, horizontal: horizontal, event: event) }
        // Horizontal gestures never reach the list: it cannot scroll sideways, and a gesture `super` sees
        // is AppKit's until it ends. A vertical one reaches it whole, its held start first.
        if case .list(let events) = route {
            for listEvent in events { super.scrollWheel(with: listEvent) }
        }
    }

    private func page(phase: ProfileSwipeTracker.Phase, horizontal: Bool, event: NSEvent) {
        let step = tracker.feed(deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY), phase: phase)
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

/// The axis of one trackpad gesture, decided once from its first few points of movement and kept through
/// its momentum, as Chrome rails a wheel scroll sequence to one axis from its start
/// (content/browser/renderer_host/input/mouse_wheel_rails_filter_mac.mm, `MouseWheelRailsFilterMac`).
/// Until it is decided the gesture's events are held, so a horizontal swipe is never handed to AppKit's
/// responsive scrolling, which would keep the rest of the gesture. A vertical decision hands every held
/// event to the list in order, from `mayBegin` on; a horizontal one drops them.
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

    /// Movement on either axis that decides it, in points: ``ProfileSwipeTracker/isHorizontal``'s 4.
    static var slop: Double { 4 }

    private(set) var axis = Axis.undecided
    private var dx = 0.0
    private var dy = 0.0
    private var held: [Event] = []

    /// Routes one precise scroll event. `phase` nil is an event outside a gesture phase; `touchDown` marks
    /// fingers landing (`mayBegin`), which starts a new gesture, as `began` does after a decided one.
    mutating func route(_ event: Event, phase: ProfileSwipeTracker.Phase?, touchDown: Bool,
                        deltaX: Double, deltaY: Double) -> Route {
        if touchDown || (phase == .began && axis != .undecided) { axis = .undecided; dx = 0; dy = 0; held = [] }
        switch phase {
        case nil:
            // A stationary event inside an undecided gesture waits with it; any other goes to the list.
            guard touchDown || !held.isEmpty else { return .list([event]) }
            held.append(event)
            return .hold
        case .began, .changed:
            guard axis == .undecided else { return routeDecided(event) }
            held.append(event)
            dx += deltaX
            dy += deltaY
            guard max(abs(dx), abs(dy)) >= Self.slop else { return .hold }
            return decide(abs(dx) > abs(dy) * 2 ? .horizontal : .vertical)
        case .ended:
            guard axis == .undecided else { return routeDecided(event) }
            // Too short to show an axis: a small scroll is still the list's, as it was before the latch.
            held.append(event)
            return decide(.vertical)
        case .momentum:
            return axis == .undecided ? .list([event]) : routeDecided(event)
        }
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

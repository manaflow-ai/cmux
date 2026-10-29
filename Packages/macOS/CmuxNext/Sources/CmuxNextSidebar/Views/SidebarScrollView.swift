import AppKit
import CmuxNextInput

/// The sidebar list's scroll view. A two-finger horizontal trackpad swipe
/// over it switches profiles instead of scrolling; vertical scrolling
/// is unchanged. One switch per gesture (`ProfileSwipeTracker`). A sideways
/// mouse wheel (tilt, or Shift) pages the spaces too, one per roll
/// (`SpaceWheelPager`); up or down always scrolls the list. Both hear the
/// app's input tap (`SidebarSwipeFeed`), not `scrollWheel(with:)`.
///
/// This class scrolls on the main thread: every event reaches the override, which keeps what the paging
/// took and hands the rest to `super` event by event. ``ResponsiveSidebarScrollView`` (feature
/// `responsiveScrolling`) scrolls on AppKit's scrolling thread instead.
class SidebarScrollView: NSScrollView {
    /// Called with -1 (previous) or +1 (next) once per qualifying swipe.
    var onHorizontalSwipe: ((Int) -> Void)? {
        get { swipes.onHorizontalSwipe }
        set { swipes.onHorizontalSwipe = newValue }
    }
    /// A horizontal gesture 1:1 (R99): its phase, finger dx and time. When
    /// set, it replaces the one-step swipe.
    var onHorizontalScroll: ((ProfileSwipeTracker.Phase, CGFloat, TimeInterval) -> Void)? {
        get { swipes.onHorizontalScroll }
        set { swipes.onHorizontalScroll = newValue }
    }
    /// A mouse wheel notch paged the spaces: -1 (previous) or +1 (next).
    var onWheelPage: ((Int) -> Void)? {
        get { swipes.onWheelPage }
        set { swipes.onWheelPage = newValue }
    }
    /// The app's one input tap (the sidebar passes the App's on): the paging hears this window's scrolls there.
    var inputTap: InputEventTap? {
        didSet { if inputTap !== oldValue { swipes.follow(tap: inputTap, window: window) } }
    }
    private(set) lazy var swipes = SidebarSwipeFeed(view: self, pagesVertically: false)
    private var latch = ScrollAxisLatch<NSEvent>()

    /// The override keeps every paged event of a gesture from `super`, so AppKit must not take a gesture over.
    override class var isCompatibleWithResponsiveScrolling: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        swipes.follow(tap: inputTap, window: window)
    }

    /// Scrolls the list unless the paging took the event (a horizontal gesture, or a sideways wheel roll). When the
    /// event moves the list up or down, a programmatic scroll's spring stops where it shows first; a sideways
    /// swipe's end or momentum leaves it running. On responsive scrolling a trackpad gesture goes through
    /// ``railed(_:)`` instead.
    override func scrollWheel(with event: NSEvent) { // local-monitor-allow: the tap feeds the paging; this override only keeps a paged event from the list and stops the spring, as the responder AppKit routes it to
        if Self.isCompatibleWithResponsiveScrolling, event.hasPreciseScrollingDeltas { return railed(event) }
        if swipes.takes(event) { return }
        scrollList(event)
    }

    private func scrollList(_ event: NSEvent) {
        if event.scrollingDeltaY != 0 { stopContentSpring() }
        super.scrollWheel(with: event)
    }

    /// AppKit sends `scrollWheel` only until a gesture reaches `super`, then tracks the rest itself (the paging
    /// still hears every event on the tap). So a gesture reaches `super` only once ``ScrollAxisLatch`` has railed
    /// it vertical, its held events first; a horizontal one never does and stays the paging's.
    private func railed(_ event: NSEvent) {
        let route = latch.route(event, phase: SidebarSwipeFeed.phase(of: event), touchDown: event.phase.contains(.mayBegin),
                                deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY))
        guard case .list(let events) = route else { return }
        for listEvent in events { scrollList(listEvent) }
    }
}

/// The sidebar list on AppKit's responsive scrolling (feature `responsiveScrolling`):
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

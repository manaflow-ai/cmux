import CoreGraphics

/// Which way a page swipe goes. Content dragged right (`scrollingDeltaX > 0`, the page
/// scrolling toward its left edge) shows the previous page, as in Safari and Chrome.
public nonisolated enum BrowserSwipeDirection: Equatable, Sendable {
    case back
    case forward

    init(deltaX: CGFloat) {
        self = deltaX > 0 ? .back : .forward
    }
}

/// What the page under the pointer does with a horizontal scroll, from the page itself
/// (`BrowserSwipeProbe`): whether the scroller under the pointer (or the document) can still
/// move left or right, and whether a page script took recent horizontal wheels for itself
/// (a carousel that calls `preventDefault`).
nonisolated struct BrowserSwipeEdges: Equatable, Sendable {
    var canScrollLeft: Bool
    var canScrollRight: Bool
    var consumesHorizontal: Bool

    /// Whether a swipe `direction` would scroll the page instead of navigating.
    func scrolls(_ direction: BrowserSwipeDirection) -> Bool {
        consumesHorizontal || (direction == .back ? canScrollLeft : canScrollRight)
    }
}

/// One trackpad scroll gesture over a Chromium page, deciding whether it becomes a Back or
/// Forward swipe (pure; `CEFSwipeNavigation` feeds it events and probe answers).
///
/// A gesture probes the page when it begins (that also installs the page's wheel listener).
/// Once it has moved `slop` points, mostly sideways, it probes again for the final answer: a
/// page that scrolls that way, or took the wheels itself, keeps the gesture. The page gets
/// every event until the answer comes, so a carousel or a wide table scrolls as before.
/// Only a swipe that starts at the scroll edge, or reaches it in a later gesture, navigates.
nonisolated struct BrowserSwipeGesture: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        /// Began; not yet moved `slop` points.
        case pending
        /// Moved sideways past `slop`; waiting for the second probe.
        case confirming(BrowserSwipeDirection)
        /// The page does not scroll that way: the next event starts the swipe.
        case ready(BrowserSwipeDirection)
        /// AppKit tracks the swipe (`trackSwipeEvent`) until it completes.
        case tracking(BrowserSwipeDirection)
        /// The page keeps this gesture.
        case declined
    }

    nonisolated enum ScrollPhase: Equatable, Sendable {
        case began
        case changed
        case ended
    }

    enum Step: Equatable, Sendable {
        case none
        /// Ask the page (`probeAnswered` with the same `generation`).
        case probe
        /// Call `trackSwipeEvent` with this event and keep it from the page.
        case track(BrowserSwipeDirection)
    }

    static let slop: CGFloat = 6
    /// Horizontal travel must be this many times the vertical.
    static let dominance: CGFloat = 1.5

    private(set) var phase: Phase = .idle
    /// Counts gestures, so a late probe answer of an earlier one is ignored.
    private(set) var generation = 0
    private var dx: CGFloat = 0
    private var dy: CGFloat = 0
    private var firstAnswer: BrowserSwipeEdges?

    /// A scroll event of the gesture (momentum events are not passed).
    mutating func scroll(_ scrollPhase: ScrollPhase, deltaX: CGFloat, deltaY: CGFloat) -> Step {
        switch scrollPhase {
        case .began:
            if case .tracking = phase { return .none }
            generation += 1
            phase = .pending
            dx = deltaX
            dy = deltaY
            firstAnswer = nil
            return .probe
        case .ended:
            if case .tracking = phase { return .none }
            phase = .idle
            return .none
        case .changed:
            dx += deltaX
            dy += deltaY
            switch phase {
            case .pending:
                if abs(dy) >= Self.slop, abs(dy) * Self.dominance > abs(dx) {
                    phase = .declined
                    return .none
                }
                guard abs(dx) >= Self.slop, abs(dx) >= Self.dominance * abs(dy) else { return .none }
                let direction = BrowserSwipeDirection(deltaX: dx)
                if let firstAnswer, firstAnswer.scrolls(direction) {
                    phase = .declined
                    return .none
                }
                phase = .confirming(direction)
                return .probe
            case .ready(let direction):
                // The fingers turned back the other way before the swipe started: the page keeps it.
                guard BrowserSwipeDirection(deltaX: dx) == direction else {
                    phase = .declined
                    return .none
                }
                phase = .tracking(direction)
                return .track(direction)
            case .idle, .confirming, .tracking, .declined:
                return .none
            }
        }
    }

    /// The page answered a probe of gesture `generation` (nil: it could not be asked).
    mutating func probeAnswered(_ edges: BrowserSwipeEdges?, generation: Int) {
        guard generation == self.generation else { return }
        switch phase {
        case .pending:
            firstAnswer = edges
        case .confirming(let direction):
            guard let edges, !edges.scrolls(direction) else {
                phase = .declined
                return
            }
            phase = .ready(direction)
        case .idle, .ready, .tracking, .declined:
            break
        }
    }

    /// The tracked swipe completed (navigated or sprang back).
    mutating func swipeFinished() {
        if case .tracking = phase { phase = .idle }
    }

    /// The pointer left the page or the feature turned off mid-gesture.
    mutating func cancel() {
        phase = .idle
    }
}

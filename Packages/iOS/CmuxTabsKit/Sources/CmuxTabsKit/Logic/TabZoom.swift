import CoreGraphics
import Foundation

/// A damped spring in SwiftUI's `spring(response:dampingFraction:)` terms.
struct ZoomSpring: Equatable, Sendable {
    var response: Double
    var damping: Double
    /// Velocity toward the target when the spring starts from rest
    /// (progress/s; Safari's close starts fast).
    var launch: Double = 0

    // Constants fitted to Mobile Safari device recordings with real frame
    // timestamps (cmux-next ios-next/reference/validation/browser-springs-verify.md).
    /// Page to card (tabs button): 0.369 / 0.873, four events agree.
    static let toOverview = ZoomSpring(response: 0.37, damping: 0.875)
    /// Card to page (Done, a card, a new tab): the middle and tail fit
    /// 0.385–0.40 / 0.98–0.99, but Safari covers 1850–2700 pt/s in the
    /// first 2–3 frames, so it starts with about 8.5 progress/s.
    static let toPage = ZoomSpring(response: 0.39, damping: 0.99, launch: 8.5)
    /// After a reversal Safari follows the destination's spring from about
    /// rest (toward the page 0.308–0.331 / 1.03–1.04, toward the grid
    /// 0.346–0.369 / 0.84–0.875).
    static let reversalToPage = ZoomSpring(response: 0.32, damping: 1.03)
    static let reversalToOverview = ZoomSpring(response: 0.36, damping: 0.86)
    /// After a pinch is released (no reference recording).
    static let release = ZoomSpring(response: 0.36, damping: 0.9)
}

/// The page <-> tab overview transition as one progress value driven by an
/// interruptible spring: 0 is the full page, 1 is the tab's card in the grid.
/// Every entry point (tabs button, Done, card tap, new tab, pinch) moves the
/// same value, so a transition can be reversed or grabbed at any point and
/// the UI's interactive state is derived from it, never from flags that an
/// animation completion has to clear.
struct TabZoomState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Settled on the full page.
        case page
        /// Settled on the grid.
        case overview
        /// Spring running toward `target`.
        case animating
        /// A pinch drives `progress` directly.
        case interactive
    }

    /// At a reversal Safari's frame jumps toward the new target in one frame
    /// (card edges: about +20 pt toward the page, −3 to −17 pt toward the
    /// grid), then starts from rest. In points of card width.
    static let reversalJumpToPage = 20.0
    static let reversalJumpToOverview = 10.0
    /// Settled when within this distance of the target, moving slower than `restVelocity`.
    static let restDistance = 0.001
    static let restVelocity = 0.01

    private(set) var progress: Double = 0
    /// Progress per second.
    private(set) var velocity: Double = 0
    /// Free translation of the zooming rect away from its page<->card path
    /// (points). A pinch moves it with the fingers; it springs back to zero
    /// with the same spring as `progress`. Taps never set it.
    private(set) var offset: CGVector = .zero
    /// Points per second.
    private(set) var offsetVelocity: CGVector = .zero
    private(set) var target: Double = 0
    private(set) var spring: ZoomSpring = .toPage
    private(set) var phase: Phase = .page

    init(overview: Bool = false) {
        progress = overview ? 1 : 0
        target = progress
        phase = overview ? .overview : .page
    }

    /// The grid takes taps only when it is settled.
    var gridInteractive: Bool { phase == .overview }
    /// The live page takes input only when it is settled.
    var pageInteractive: Bool { phase == .page }
    /// Moving or heading to (or showing) the grid.
    var showsOverview: Bool { phase != .page }
    var headingToOverview: Bool { target == 1 }

    /// Tabs button / Done: go to `overview`, reversing a running transition
    /// from where it is.
    /// `span` is the card-width travel in points (screen width − card width),
    /// to turn the reversal jump into progress.
    mutating func go(toOverview: Bool, span: Double = 244) {
        let newTarget: Double = toOverview ? 1 : 0
        switch phase {
        case .page where !toOverview, .overview where toOverview:
            return
        case .animating where newTarget == target:
            return
        case .animating:
            // Reversal: one-frame jump toward the new target, then the
            // destination's spring from rest.
            let jump = (toOverview ? Self.reversalJumpToOverview : Self.reversalJumpToPage) / max(1, span)
            progress += toOverview ? jump : -jump
            animate(to: newTarget, spring: toOverview ? .reversalToOverview : .reversalToPage, keepVelocity: 0)
        case .interactive:
            animate(to: newTarget, spring: .release, keepVelocity: 1)
        case .page, .overview:
            let spring: ZoomSpring = toOverview ? .toOverview : .toPage
            animate(to: newTarget, spring: spring, keepVelocity: 0)
            velocity = toOverview ? spring.launch : -spring.launch
        }
    }

    /// Starts a transition from an explicit progress (a new tab grows from
    /// its slot: start at 1, go to the page).
    mutating func start(from progress: Double, toOverview: Bool) {
        self.progress = progress
        velocity = 0
        offset = .zero
        offsetVelocity = .zero
        let spring: ZoomSpring = toOverview ? .toOverview : .toPage
        animate(to: toOverview ? 1 : 0, spring: spring, keepVelocity: 0)
        velocity = toOverview ? spring.launch : -spring.launch
    }

    mutating func animate(to target: Double, spring: ZoomSpring, keepVelocity: Double) {
        self.target = target
        self.spring = spring
        velocity *= keepVelocity
        offsetVelocity = CGVector(dx: offsetVelocity.dx * keepVelocity, dy: offsetVelocity.dy * keepVelocity)
        phase = .animating
        if isAtRest { settle() }
    }

    // MARK: Pinch

    /// Grabs the current presentation (progress, offset) wherever it is,
    /// including mid-spring; tracking continues from there with no jump.
    mutating func beginInteraction() {
        phase = .interactive
        velocity = 0
        offsetVelocity = .zero
    }

    /// `progress` may leave 0...1 a little (rubber band); `velocity` is progress/s.
    mutating func updateInteraction(progress: Double, velocity: Double) {
        guard phase == .interactive else { return }
        self.progress = min(1.08, max(-0.08, progress))
        self.velocity = velocity
    }

    /// Pinch tracking: progress and free translation set directly every
    /// event (no filtering), with their current velocities for the release.
    mutating func updateInteraction(progress: Double, offset: CGVector, velocity: Double, offsetVelocity: CGVector) {
        guard phase == .interactive else { return }
        self.progress = progress
        self.offset = offset
        self.velocity = velocity
        self.offsetVelocity = offsetVelocity
    }

    /// Releases a pinch toward `toOverview`, keeping every velocity component
    /// (no discontinuity), and springs progress and translation from there.
    mutating func release(toOverview: Bool) {
        guard phase == .interactive else { return }
        animate(to: toOverview ? 1 : 0, spring: .release, keepVelocity: 1)
    }

    /// Completes toward the grid past half way or when moving toward it fast
    /// enough, else springs back. Returns whether it goes to the grid.
    @discardableResult
    mutating func endInteraction(velocity: Double, startedFromOverview: Bool) -> Bool {
        guard phase == .interactive else { return target == 1 }
        self.velocity = velocity
        let projected = progress + velocity * 0.15
        let toOverview: Bool
        if abs(velocity) > 1.2 { toOverview = velocity > 0 } else { toOverview = projected > 0.5 }
        _ = startedFromOverview
        animate(to: toOverview ? 1 : 0, spring: .release, keepVelocity: 1)
        return toOverview
    }

    /// Ends an interaction or transition without animating (tab closed, reset).
    mutating func jump(toOverview: Bool) {
        progress = toOverview ? 1 : 0
        target = progress
        velocity = 0
        offset = .zero
        offsetVelocity = .zero
        phase = toOverview ? .overview : .page
    }

    // MARK: Integration

    private var isAtRest: Bool {
        abs(progress - target) < Self.restDistance && abs(velocity) < Self.restVelocity
            && abs(offset.dx) < 0.25 && abs(offset.dy) < 0.25
            && abs(offsetVelocity.dx) < 2 && abs(offsetVelocity.dy) < 2
    }

    private mutating func settle() {
        progress = target
        velocity = 0
        offset = .zero
        offsetVelocity = .zero
        phase = target == 1 ? .overview : .page
    }

    /// Advances the spring by `dt` seconds. Returns true when it settled in this step.
    @discardableResult
    mutating func step(_ dt: Double) -> Bool {
        guard phase == .animating, dt > 0 else { return false }
        let w = 2 * Double.pi / spring.response
        // Semi-implicit Euler in small substeps (stable for any frame time).
        var remaining = min(dt, 0.1)
        while remaining > 0 {
            let h = min(remaining, 1.0 / 600)
            let x = progress - target
            let a = -w * w * x - 2 * spring.damping * w * velocity
            velocity += a * h
            progress += velocity * h
            let ax = -w * w * offset.dx - 2 * spring.damping * w * offsetVelocity.dx
            let ay = -w * w * offset.dy - 2 * spring.damping * w * offsetVelocity.dy
            offsetVelocity.dx += ax * h
            offsetVelocity.dy += ay * h
            offset.dx += offsetVelocity.dx * h
            offset.dy += offsetVelocity.dy * h
            remaining -= h
        }
        if isAtRest {
            settle()
            return true
        }
        return false
    }
}

/// Maps the zoom state to the zooming rect: the page<->card path at
/// `progress` (each edge interpolated, so the aspect goes from the screen's
/// to the card's) plus the free `offset`.
struct ZoomRectPath: Equatable, Sendable {
    var full: CGRect
    var card: CGRect

    func rect(progress p: Double, offset: CGVector = .zero) -> CGRect {
        let t = CGFloat(p)
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        return CGRect(x: lerp(full.minX, card.minX) + offset.dx, y: lerp(full.minY, card.minY) + offset.dy,
                      width: lerp(full.width, card.width), height: lerp(full.height, card.height))
    }

    /// Progress at which the rect is `width` wide (linear in width).
    func progress(forWidth width: CGFloat) -> Double {
        let span = full.width - card.width
        return span == 0 ? 0 : Double((full.width - width) / span)
    }
}

/// 1:1 pinch tracking. At the start it takes the zooming rect as presented
/// and the fingers' centroid; afterwards the rect's width is the start width
/// times the pinch scale (rubber-banded past the card and past the full
/// page) and the point of the page that was under the centroid stays under
/// the centroid.
struct PinchTracker: Equatable, Sendable {
    let startRect: CGRect
    let startCentroid: CGPoint
    /// Rubber-band room in progress units beyond the card and beyond the page.
    static let bandBeyondCard = 0.35
    static let bandBeyondPage = 0.12

    init(startRect: CGRect, startCentroid: CGPoint) {
        self.startRect = startRect
        self.startCentroid = startCentroid
    }

    /// UIScrollView-style rubber band: past the limit the value moves with
    /// diminishing returns, never more than `dimension` beyond it.
    static func rubberBand(_ overshoot: Double, dimension: Double) -> Double {
        guard overshoot > 0, dimension > 0 else { return overshoot }
        return (1 - 1 / (overshoot * 0.55 / dimension + 1)) * dimension
    }

    /// Where the anchor sits inside the rect, as a fraction of its size.
    var anchor: CGPoint {
        CGPoint(x: startRect.width > 0 ? (startCentroid.x - startRect.minX) / startRect.width : 0.5,
                y: startRect.height > 0 ? (startCentroid.y - startRect.minY) / startRect.height : 0.5)
    }

    /// Progress (rubber-banded) and free offset for the fingers at `scale`
    /// (relative to the start) and `centroid`.
    func state(scale: CGFloat, centroid: CGPoint, path: ZoomRectPath) -> (progress: Double, offset: CGVector) {
        let raw = path.progress(forWidth: startRect.width * scale)
        let p: Double
        if raw > 1 {
            p = 1 + Self.rubberBand(raw - 1, dimension: Self.bandBeyondCard)
        } else if raw < 0 {
            p = -Self.rubberBand(-raw, dimension: Self.bandBeyondPage)
        } else {
            p = raw
        }
        let onPath = path.rect(progress: p)
        let a = anchor
        let origin = CGPoint(x: centroid.x - a.x * onPath.width, y: centroid.y - a.y * onPath.height)
        return (p, CGVector(dx: origin.x - onPath.minX, dy: origin.y - onPath.minY))
    }

    /// Release decision from the projected (velocity-carried) state: to the
    /// grid when the page would shrink below 75 % of its width, or when it
    /// moves inward fast; from the grid, to the page when the card would grow
    /// past a quarter of the way.
    static func releaseToOverview(progress p: Double, velocity v: Double, startedFromOverview: Bool, path: ZoomRectPath) -> Bool {
        let projected = p + v * 0.2
        if abs(v) > 2.5 { return v > 0 }
        if startedFromOverview { return projected > 0.75 }
        let widthRatio = path.rect(progress: projected).width / max(1, path.full.width)
        return widthRatio < 0.75
    }
}

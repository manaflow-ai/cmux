import CoreGraphics

/// A drag on the bottom bar: sideways switches tabs, up opens the tab grid
/// (Safari's Compact layout), following the finger.
///
/// The page tracks the thumb 1:1, as Safari's does: the point of the page
/// that was under the thumb when the drag engaged stays under it, and the
/// page shrinks linearly with how far the thumb has travelled up (no time
/// curve, no gain). Past the card's size, and below where it started, it
/// rubber-bands. Releasing springs from the thumb's velocity
/// (`releaseVelocity`), so a fling carries on and a turn back down returns.
///
/// Before, the drag started Safari's recorded swipe-up curve on its own
/// clock the moment it was recognised, and read progress off that curve by
/// travel (`up / 1000 pt/s`), which put 17 pt of thumb at 0.12 of the way
/// and 100 pt at 0.51: the page ran ahead of the thumb and sped up by
/// itself (Leo, 2026-11-12: "It goes too fast. It accelerates too fast.").
struct BarSwipe: Equatable, Sendable {
    enum Axis: Equatable, Sendable { case horizontal, up, down }

    /// Thumb travel (points) that shrinks the page to its card's size.
    /// Safari's page is about 0.67 of the way to its card after a 250 pt
    /// swipe (tabs-parity audit 1d), so 375 pt.
    static let travel: CGFloat = 375
    /// Rubber-band room past the card (progress) and below the start (points).
    static let bandBeyondCard = 0.25
    static let bandBelowStart: CGFloat = 60
    /// A release this fast (pt/s) goes the way it moves; slower, by position.
    static let flingSpeed: CGFloat = 250
    /// A slow release past this progress (projected 0.15 s on) opens the grid.
    static let commitProgress = 0.25

    /// The page's rect when the drag engaged (full screen).
    let startRect: CGRect
    /// The thumb when the drag engaged (past the slop): tracking is relative
    /// to it, so the first tracked frame does not jump by the slop.
    let startFinger: CGPoint

    init(startRect: CGRect, startFinger: CGPoint) {
        self.startRect = startRect
        self.startFinger = startFinger
    }

    /// The drag's direction from its first movement past the slop.
    static func axis(_ translation: CGSize) -> Axis {
        if abs(translation.width) > abs(translation.height) { return .horizontal }
        return translation.height < 0 ? .up : .down
    }

    /// Where the held point sits inside the page, as a fraction of its size.
    var anchor: CGPoint {
        CGPoint(x: startRect.width > 0 ? (startFinger.x - startRect.minX) / startRect.width : 0.5,
                y: startRect.height > 0 ? (startFinger.y - startRect.minY) / startRect.height : 0.9)
    }

    /// Zoom progress for `up` points of upward travel: linear, rubber-banded
    /// past the card (and 0 below the start, where the page moves instead).
    static func progress(up: CGFloat) -> Double {
        let raw = Double(up / travel)
        if raw > 1 { return 1 + PinchTracker.rubberBand(raw - 1, dimension: bandBeyondCard) }
        return max(0, raw)
    }

    /// Progress and free offset with the thumb at `finger`: the held point
    /// of the page is under the thumb (below the start, rubber-banded).
    func state(finger: CGPoint, path: ZoomRectPath) -> (progress: Double, offset: CGVector) {
        let up = startFinger.y - finger.y
        let p = Self.progress(up: up)
        let onPath = path.rect(progress: p)
        let a = anchor
        var target = finger
        if up < 0 {
            target.y = startFinger.y + CGFloat(PinchTracker.rubberBand(Double(-up), dimension: Double(Self.bandBelowStart)))
        }
        let origin = CGPoint(x: target.x - a.x * onPath.width, y: target.y - a.y * onPath.height)
        return (p, CGVector(dx: origin.x - onPath.minX, dy: origin.y - onPath.minY))
    }

    /// The held point's position for a state (what the tracking test measures).
    func heldPoint(progress: Double, offset: CGVector, path: ZoomRectPath) -> CGPoint {
        let r = path.rect(progress: progress, offset: offset)
        let a = anchor
        return CGPoint(x: r.minX + a.x * r.width, y: r.minY + a.y * r.height)
    }

    /// Progress/s and offset pt/s for the thumb at `finger` moving at
    /// `velocity` (pt/s): the release starts at the thumb's own speed.
    func releaseVelocity(finger: CGPoint, velocity: CGVector, path: ZoomRectPath) -> (p: Double, o: CGVector) {
        let h: CGFloat = 1.0 / 240
        let a = state(finger: finger, path: path)
        let b = state(finger: CGPoint(x: finger.x + velocity.dx * h, y: finger.y + velocity.dy * h), path: path)
        let dt = Double(h)
        return ((b.progress - a.progress) / dt,
                CGVector(dx: (b.offset.dx - a.offset.dx) / h, dy: (b.offset.dy - a.offset.dy) / h))
    }

    /// Release decision: a fling goes the way it moves; a slow release opens
    /// the grid once the page is a quarter of the way to its card.
    /// `velocityUp` is the thumb's upward speed (pt/s).
    static func releaseToOverview(progress: Double, velocityUp: CGFloat) -> Bool {
        if velocityUp > flingSpeed { return true }
        if velocityUp < -flingSpeed { return false }
        return progress + Double(velocityUp / travel) * 0.15 > commitProgress
    }
}

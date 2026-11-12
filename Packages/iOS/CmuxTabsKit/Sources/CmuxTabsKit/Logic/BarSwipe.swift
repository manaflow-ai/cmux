import CoreGraphics

/// A drag on the bottom bar: sideways switches tabs, up opens the tab grid
/// (Safari's Compact layout), following the finger.
///
/// Safari keeps the page under the thumb for the whole swipe up: its bottom
/// edge (where the bar is) rises with the finger toward its card, and on
/// release it springs on (or back) at the finger's speed. Nothing runs on its
/// own clock while the finger is down. (The page used to replay Safari's
/// swipe-up curve in time from the first movement, so a slow thumb watched
/// the page run ahead of it and accelerate away.)
struct BarSwipe: Equatable, Sendable {
    enum Axis: Equatable, Sendable { case horizontal, up, down }

    /// Finger travel (points) for the whole page-to-card zoom when the card is
    /// not known, and the least travel ever used: a card low on the screen
    /// still takes a deliberate swipe.
    static let defaultTravel: CGFloat = 450
    static let minimumTravel: CGFloat = 200
    /// Rubber band past the card and back below the page (progress units).
    static let bandBeyondCard = 0.12
    static let bandBeyondPage = 0.05
    /// Release: an upward flick faster than this (progress/s, about 540 pt/s
    /// over the default travel) goes on to the grid; a finger moving back down
    /// faster than `reverseVelocity` (about 45 pt/s) returns to the page;
    /// otherwise where the page would coast to in `projection` seconds
    /// decides, past half way to the grid.
    static let flickVelocity = 1.2
    static let reverseVelocity = 0.1
    static let projection = 0.15

    /// The drag's direction from its first movement past the slop.
    static func axis(_ translation: CGSize) -> Axis {
        if abs(translation.width) > abs(translation.height) { return .horizontal }
        return translation.height < 0 ? .up : .down
    }

    /// Finger travel that takes the page to its card: the distance its bottom
    /// edge moves along `path`.
    static func travel(path: ZoomRectPath?) -> CGFloat {
        guard let path, path.full.height > 0, path.card.height > 0 else { return defaultTravel }
        return max(minimumTravel, path.full.maxY - path.card.maxY)
    }

    /// Zoom progress (0 page, 1 grid) for an upward translation: linear in
    /// the finger's travel, rubber-banded past either end.
    static func progress(up: CGFloat, travel: CGFloat) -> Double {
        let raw = Double(up / max(1, travel))
        if raw > 1 { return 1 + PinchTracker.rubberBand(raw - 1, dimension: bandBeyondCard) }
        if raw < 0 { return -PinchTracker.rubberBand(-raw, dimension: bandBeyondPage) }
        return raw
    }

    /// The finger's upward speed (points/s) in progress per second: the
    /// spring that takes over on release starts at exactly this speed.
    static func velocity(_ velocity: CGFloat, travel: CGFloat) -> Double { Double(velocity / max(1, travel)) }

    /// On release: on to the grid, or back to the page. `progress` and
    /// `velocity` are the page's (progress, progress/s).
    static func releaseToOverview(progress: Double, velocity: Double) -> Bool {
        if velocity > flickVelocity { return true }
        if velocity < -reverseVelocity { return false }
        return progress + velocity * projection > 0.5
    }
}

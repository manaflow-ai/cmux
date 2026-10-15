import CoreGraphics

/// A drag on the bottom bar: sideways switches tabs, up opens the tab grid
/// (Safari's Compact layout), following the finger.
///
/// Safari (cmux-next tabs-parity-audit 1d, `1-zoom/out-swipe.png`): the page follows a
/// swipe up steeply, about 0.67 of the way to its card when the finger
/// lifts, then springs to the grid (t99 390–442 ms).
struct BarSwipe: Equatable, Sendable {
    enum Axis: Equatable, Sendable { case horizontal, up, down }

    /// The page follows the finger steeply at first and levels off: Safari's
    /// progress for a 270 pt / 0.2 s swipe is 0.20 / 0.43 / 0.50 / 0.58 /
    /// 0.64 / 0.67 at 17 / 33 / 50 / 70 / 90 / 110 ms (cmux-next tabs-parity-audit
    /// 1d), which `reach · (1 − e^(−up / scale))` follows within 0.04.
    static let reach = 0.72
    static let scale: CGFloat = 55

    /// The drag's direction from its first movement past the slop.
    static func axis(_ translation: CGSize) -> Axis {
        if abs(translation.width) > abs(translation.height) { return .horizontal }
        return translation.height < 0 ? .up : .down
    }

    /// Zoom progress (0 page, 1 grid) for an upward translation.
    static func progress(up: CGFloat) -> Double { reach * (1 - exp(-Double(max(0, up) / scale))) }
    /// Progress per second for an upward velocity at `up`.
    static func velocity(up: CGFloat, velocity: CGFloat) -> Double {
        reach / Double(scale) * exp(-Double(max(0, up) / scale)) * Double(velocity)
    }
}

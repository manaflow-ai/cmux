import CoreGraphics

/// A drag on the bottom bar: sideways switches tabs, up opens the tab grid
/// (Safari's Compact layout), following the finger.
///
/// Safari (cmux-next tabs-parity-audit 1d): a 270 pt swipe up
/// over 0.2 s has the page about 0.6 of the way to its card when the finger
/// lifts, then it springs to the grid (t99 390–442 ms).
struct BarSwipe: Equatable, Sendable {
    enum Axis: Equatable, Sendable { case horizontal, up, down }

    /// Upward travel for the whole page -> card zoom.
    static let distance: CGFloat = 450

    /// The drag's direction from its first movement past the slop.
    static func axis(_ translation: CGSize) -> Axis {
        if abs(translation.width) > abs(translation.height) { return .horizontal }
        return translation.height < 0 ? .up : .down
    }

    /// Zoom progress (0 page, 1 grid) for an upward translation.
    static func progress(up: CGFloat) -> Double { Double(up / distance) }
    /// Progress per second for an upward velocity.
    static func velocity(up: CGFloat) -> Double { Double(up / distance) }
}

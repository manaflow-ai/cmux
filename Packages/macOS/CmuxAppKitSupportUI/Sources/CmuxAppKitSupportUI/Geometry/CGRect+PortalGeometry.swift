public import AppKit

extension CGRect {
    /// Whether `self` and `other` are equal within `epsilon` on every origin and
    /// size component. Callers pass the tolerance explicitly so each comparison
    /// site keeps its own intended slack.
    public func isApproximatelyEqual(to other: CGRect, epsilon: CGFloat) -> Bool {
        abs(origin.x - other.origin.x) <= epsilon &&
            abs(origin.y - other.origin.y) <= epsilon &&
            abs(size.width - other.size.width) <= epsilon &&
            abs(size.height - other.size.height) <= epsilon
    }

    /// Returns `self` snapped to device pixels using `view`'s backing scale
    /// factor (falling back to the main screen's, then 1.0). Non-finite rects are
    /// returned unchanged; snapped width and height are clamped to be non-negative.
    public func pixelSnapped(in view: NSView) -> CGRect {
        guard origin.x.isFinite,
              origin.y.isFinite,
              size.width.isFinite,
              size.height.isFinite else {
            return self
        }
        let scale = max(1.0, view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0)
        func snap(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded(.toNearestOrAwayFromZero) / scale
        }
        return CGRect(
            x: snap(origin.x),
            y: snap(origin.y),
            width: max(0, snap(size.width)),
            height: max(0, snap(size.height))
        )
    }
}

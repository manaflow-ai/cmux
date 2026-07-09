public import AppKit

extension CGRect {
    /// Whether every origin and size component is finite (not NaN or infinite).
    /// Portal geometry methods gate frame math on this so a non-finite anchor
    /// conversion never propagates into Auto Layout or layer frames.
    public var hasFiniteComponents: Bool {
        origin.x.isFinite &&
            origin.y.isFinite &&
            size.width.isFinite &&
            size.height.isFinite
    }

    /// Whether `self` and `other` are equal within `epsilon` on every origin and
    /// size component. Callers pass the tolerance explicitly so each comparison
    /// site keeps its own intended slack.
    public func isApproximatelyEqual(to other: CGRect, epsilon: CGFloat) -> Bool {
        abs(origin.x - other.origin.x) <= epsilon &&
            abs(origin.y - other.origin.y) <= epsilon &&
            abs(size.width - other.size.width) <= epsilon &&
            abs(size.height - other.size.height) <= epsilon
    }

    /// Whether `self` (a view frame) differs from `bounds` beyond `epsilon` on any
    /// edge-aligned component. Compares `minX`/`minY`/`width`/`height` so a hosted
    /// webview frame reset is skipped when the frame already fills its container.
    public func differsFromBounds(_ bounds: CGRect, epsilon: CGFloat) -> Bool {
        abs(minX - bounds.minX) > epsilon ||
            abs(minY - bounds.minY) > epsilon ||
            abs(width - bounds.width) > epsilon ||
            abs(height - bounds.height) > epsilon
    }

    /// Returns `self` snapped to device pixels using `view`'s backing scale
    /// factor (falling back to the main screen's, then 1.0). Non-finite rects are
    /// returned unchanged; snapped width and height are clamped to be non-negative.
    ///
    /// `@MainActor`: reads `NSView.window`/`backingScaleFactor` + `NSScreen.main`,
    /// main-actor under Swift 6.1 (CI Xcode 16.4). Sibling pure-CGRect methods stay
    /// nonisolated.
    @MainActor
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

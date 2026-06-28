public import AppKit

extension NSRect {
    /// Whether `point` falls within this rect using inclusive edges on all four
    /// sides (unlike `NSRect.contains`, which treats the max edges as open).
    /// Used as the divider hit-test for the browser window portal's resize
    /// divider, where a click exactly on the max edge should still register.
    public func portalDividerHitContains(_ point: NSPoint) -> Bool {
        point.x >= minX &&
            point.x <= maxX &&
            point.y >= minY &&
            point.y <= maxY
    }

    /// Whether this frame differs from `bounds` on any of origin-x, origin-y,
    /// width, or height by more than `epsilon`. Used by the browser portal slot
    /// to decide whether a plain hosted `WKWebView` frame needs resetting back to
    /// its container bounds (sub-pixel drift within the tolerance is ignored).
    ///
    /// - Parameters:
    ///   - bounds: the reference rect the frame should match.
    ///   - epsilon: per-component tolerance. Defaults to `0.5`.
    public func portalFrameDiffers(fromBounds bounds: NSRect, epsilon: CGFloat = 0.5) -> Bool {
        abs(minX - bounds.minX) > epsilon ||
            abs(minY - bounds.minY) > epsilon ||
            abs(width - bounds.width) > epsilon ||
            abs(height - bounds.height) > epsilon
    }

    /// This rect snapped to whole device pixels for `view`'s backing scale, so a
    /// hosted web view's frame lands on pixel boundaries and avoids blurry
    /// seams. Non-finite components are returned unchanged; width and height are
    /// clamped to be non-negative after snapping. Falls back to the main
    /// screen's scale, then `1.0`, when the view is not yet in a window.
    public func portalPixelSnapped(in view: NSView) -> NSRect {
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
        return NSRect(
            x: snap(origin.x),
            y: snap(origin.y),
            width: max(0, snap(size.width)),
            height: max(0, snap(size.height))
        )
    }
}

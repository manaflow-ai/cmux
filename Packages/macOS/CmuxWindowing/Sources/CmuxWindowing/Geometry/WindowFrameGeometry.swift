public import CoreGraphics

/// Pure window-placement math shared by session restore (`AppDelegate`) and
/// the live display-change rescue (`MainWindowScreenRescueCore`), so the two
/// paths can never disagree on where a frame lands.
public struct WindowFrameGeometry: Sendable {
    /// Creates a stateless frame-geometry helper.
    public init() {}

    /// Clamps `frame` into `visibleFrame`, flooring the size at
    /// `minWidth`/`minHeight` (or the visible frame's own size when smaller).
    /// Returns `frame` unchanged when `visibleFrame` is degenerate.
    public func clampFrame(
        _ frame: CGRect,
        within visibleFrame: CGRect,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        guard visibleFrame.width.isFinite,
              visibleFrame.height.isFinite,
              visibleFrame.width > 0,
              visibleFrame.height > 0 else {
            return frame
        }

        let maxWidth = max(visibleFrame.width, 1)
        let maxHeight = max(visibleFrame.height, 1)
        let widthFloor = min(minWidth, maxWidth)
        let heightFloor = min(minHeight, maxHeight)

        let width = min(max(frame.width, widthFloor), maxWidth)
        let height = min(max(frame.height, heightFloor), maxHeight)
        let maxX = visibleFrame.maxX - width
        let maxY = visibleFrame.maxY - height
        let x = min(max(frame.minX, visibleFrame.minX), maxX)
        let y = min(max(frame.minY, visibleFrame.minY), maxY)

        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Area of the overlap between two rects; 0 when they do not intersect.
    public func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }

    /// Squared distance from `rect`'s center to `point` (for nearest-display
    /// comparisons, where the square root is unnecessary).
    public func distanceSquared(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = rect.midX - point.x
        let dy = rect.midY - point.y
        return (dx * dx) + (dy * dy)
    }
}

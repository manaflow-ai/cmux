import Foundation

/// Pure viewport math: scroll-to-reveal targets and overview magnification.
public struct CanvasViewportMath: Sendable {
    /// Creates the math helper.
    public init() {}

    /// Computes the minimal scroll origin that brings a rect into view.
    ///
    /// Scrolls only as far as needed, per axis. A target already fully on
    /// screen along an axis keeps that axis's origin, even when it sits inside
    /// the margin, so moving focus between visible panes never pans. A target
    /// that is off screen or cut off is scrolled in with the margin, and one
    /// larger than the viewport aligns its top-left corner (plus margin).
    ///
    /// - Parameters:
    ///   - target: The rect to reveal, in canvas coordinates.
    ///   - viewportOrigin: The current scroll origin.
    ///   - viewportSize: The visible viewport size in canvas points.
    ///   - margin: Breathing room kept between the target and viewport edges.
    /// - Returns: The new scroll origin.
    public func originToReveal(
        _ target: CanvasRect,
        viewportOrigin: CanvasPoint,
        viewportSize: CanvasSize,
        margin: Double
    ) -> CanvasPoint {
        CanvasPoint(
            x: axisOriginToReveal(
                targetMin: target.minX,
                targetMax: target.maxX,
                margin: margin,
                viewportMin: viewportOrigin.x,
                viewportLength: viewportSize.width
            ),
            y: axisOriginToReveal(
                targetMin: target.minY,
                targetMax: target.maxY,
                margin: margin,
                viewportMin: viewportOrigin.y,
                viewportLength: viewportSize.height
            )
        )
    }

    /// Computes the magnification that fits a content rect inside a viewport.
    ///
    /// - Parameters:
    ///   - content: The content bounds to fit.
    ///   - viewportSize: The viewport size in unmagnified points.
    ///   - padding: Padding kept around the content at the resulting scale.
    ///   - range: Allowed magnification range; the result is clamped into it.
    /// - Returns: The clamped fit magnification. Degenerate content returns
    ///   the range's upper bound clamped to `1`.
    public func magnificationToFit(
        _ content: CanvasRect,
        in viewportSize: CanvasSize,
        padding: Double,
        range: ClosedRange<Double>
    ) -> Double {
        let paddedWidth = content.width + padding * 2
        let paddedHeight = content.height + padding * 2
        guard paddedWidth > 0, paddedHeight > 0,
              viewportSize.width > 0, viewportSize.height > 0 else {
            return min(1, range.upperBound)
        }
        let fit = min(viewportSize.width / paddedWidth, viewportSize.height / paddedHeight)
        return min(max(fit, range.lowerBound), range.upperBound)
    }

    private func axisOriginToReveal(
        targetMin: Double,
        targetMax: Double,
        margin: Double,
        viewportMin: Double,
        viewportLength: Double
    ) -> Double {
        if targetMin >= viewportMin, targetMax <= viewportMin + viewportLength {
            return viewportMin
        }
        let paddedMin = targetMin - margin
        let paddedMax = targetMax + margin
        let origin: Double
        if paddedMax - paddedMin >= viewportLength || paddedMin < viewportMin {
            origin = paddedMin
        } else if paddedMax > viewportMin + viewportLength {
            origin = paddedMax - viewportLength
        } else {
            origin = viewportMin
        }
        // A target that fits without its margin still ends up fully on
        // screen; the margin shrinks instead.
        guard targetMax - targetMin <= viewportLength else { return origin }
        return min(max(origin, targetMax - viewportLength), targetMin)
    }
}

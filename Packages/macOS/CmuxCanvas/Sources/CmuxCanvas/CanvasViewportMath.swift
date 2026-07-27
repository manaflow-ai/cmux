import Foundation

/// Pure viewport math: scroll-to-reveal targets and overview magnification.
public struct CanvasViewportMath: Sendable {
    /// Creates the math helper.
    public init() {}

    /// Computes the minimal scroll origin that brings a rect into view.
    ///
    /// Scrolls only as far as needed: a target already visible (with margin)
    /// returns the current origin unchanged. A target larger than the
    /// viewport aligns its top-left corner (plus margin).
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
                targetMin: target.minX - margin,
                targetMax: target.maxX + margin,
                viewportMin: viewportOrigin.x,
                viewportLength: viewportSize.width
            ),
            y: axisOriginToReveal(
                targetMin: target.minY - margin,
                targetMax: target.maxY + margin,
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
        viewportMin: Double,
        viewportLength: Double
    ) -> Double {
        if targetMax - targetMin >= viewportLength {
            return targetMin
        }
        if targetMin < viewportMin {
            return targetMin
        }
        if targetMax > viewportMin + viewportLength {
            return targetMax - viewportLength
        }
        return viewportMin
    }
}

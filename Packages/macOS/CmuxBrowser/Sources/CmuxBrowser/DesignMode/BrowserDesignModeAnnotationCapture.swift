/// Derives a context-rich annotation capture rectangle from freehand stroke bounds.
public struct BrowserDesignModeAnnotationCapture: Equatable, Sendable {
    /// The number of CSS viewport points added around every side of a stroke.
    public let contextPadding: Double

    /// Creates annotation capture geometry with a caller-selected padding.
    /// - Parameter contextPadding: Context added to each edge before viewport clamping.
    public init(contextPadding: Double) {
        self.contextPadding = max(0, contextPadding)
    }

    /// Expands stroke bounds and clamps the result to the visible viewport.
    /// - Parameters:
    ///   - strokeBounds: The freehand stroke's bounds in CSS viewport points.
    ///   - viewport: The viewport associated with the stroke.
    /// - Returns: A nonnegative context rectangle contained by `viewport`.
    public func contextRect(
        around strokeBounds: BrowserDesignModeRect,
        in viewport: BrowserDesignModeViewport
    ) -> BrowserDesignModeRect {
        guard viewport.width > 0, viewport.height > 0 else {
            return BrowserDesignModeRect(x: 0, y: 0, width: 0, height: 0)
        }
        let minX = max(0, min(viewport.width, strokeBounds.x - contextPadding))
        let minY = max(0, min(viewport.height, strokeBounds.y - contextPadding))
        let maxX = max(minX, min(viewport.width, strokeBounds.x + max(0, strokeBounds.width) + contextPadding))
        let maxY = max(minY, min(viewport.height, strokeBounds.y + max(0, strokeBounds.height) + contextPadding))
        return BrowserDesignModeRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }
}

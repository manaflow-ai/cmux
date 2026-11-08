public import CoreGraphics

/// CSS-coordinate page metrics used to capture and stitch browser screenshots.
public struct BrowserViewportContentMetrics: Equatable, Sendable {
    /// Full document size in CSS pixels.
    public let contentSize: CGSize

    /// Visible viewport size in CSS pixels.
    public let viewportSize: CGSize

    /// Current document scroll offset in CSS pixels.
    public let scrollOffset: CGPoint

    /// Creates validated metrics, preferring the page-reported CSS viewport over AppKit geometry.
    ///
    /// - Parameters:
    ///   - contentSize: Full document size reported by page JavaScript.
    ///   - reportedViewportSize: `window.innerWidth` and `window.innerHeight` in CSS pixels.
    ///   - fallbackViewportSize: Logical viewport derived from the WebView when JavaScript omits dimensions.
    ///   - scrollOffset: Current document scroll position in CSS pixels.
    public init?(
        contentSize: CGSize,
        reportedViewportSize: CGSize,
        fallbackViewportSize: CGSize,
        scrollOffset: CGPoint
    ) {
        guard Self.isValid(contentSize) else { return nil }
        let viewportSize = Self.isValid(reportedViewportSize)
            ? reportedViewportSize
            : fallbackViewportSize
        guard Self.isValid(viewportSize) else { return nil }

        self.contentSize = contentSize
        self.viewportSize = viewportSize
        self.scrollOffset = CGPoint(
            x: scrollOffset.x.isFinite ? scrollOffset.x : 0,
            y: scrollOffset.y.isFinite ? scrollOffset.y : 0
        )
    }

    /// Returns a full-content snapshot rect only when CSS and WebView coordinates are unscaled.
    ///
    /// WebKit requires snapshot rects in view coordinates. Callers must use a tiled capture path
    /// when page zoom or another bounds transform makes those coordinates differ from CSS pixels.
    ///
    /// - Parameters:
    ///   - webViewBounds: Current bounds of the WebView in view coordinates.
    ///   - tolerance: Maximum point difference accepted on either viewport dimension.
    /// - Returns: The CSS-sized full-content rect, or `nil` when coordinate conversion is required.
    public func untransformedFullContentSnapshotRect(
        in webViewBounds: CGRect,
        tolerance: Double = 0.5
    ) -> CGRect? {
        guard Self.isValid(webViewBounds.size),
              tolerance.isFinite,
              tolerance >= 0,
              abs(webViewBounds.width - viewportSize.width) <= tolerance,
              abs(webViewBounds.height - viewportSize.height) <= tolerance else {
            return nil
        }
        return CGRect(origin: .zero, size: contentSize)
    }

    private static func isValid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}

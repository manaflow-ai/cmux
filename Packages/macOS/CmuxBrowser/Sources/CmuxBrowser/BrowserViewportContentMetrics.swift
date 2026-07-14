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

    private static func isValid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}

public import CoreGraphics

/// The viewport positions a stitched full-page capture scrolls to, in CSS
/// pixels, row by row. The page clamps the last row and column to its
/// scroll range, so each tile is drawn where the page actually scrolled.
public nonisolated struct BrowserFullPagePlan: Equatable, Sendable {
    /// The largest document a full-page capture takes, in CSS pixels (a
    /// 2x bitmap of it is about 400 MB).
    public static let maximumPixels: Double = 25_000_000
    /// Each tile scrolls, waits for a frame and snapshots; more would miss
    /// the screenshot deadline.
    public static let maximumTiles = 48

    public let contentSize: CGSize
    public let viewportSize: CGSize
    public let origins: [CGPoint]

    /// Whether a document of `contentSize` can be captured at all.
    public static func isCapturable(contentSize: CGSize) -> Bool {
        [contentSize.width, contentSize.height].allSatisfy { $0.isFinite && $0 > 0 }
            && Double(contentSize.width * contentSize.height) <= maximumPixels
    }

    /// Nil when a size is empty or not finite, or the page is too large.
    public init?(contentSize: CGSize, viewportSize: CGSize) {
        guard Self.isCapturable(contentSize: contentSize),
              [viewportSize.width, viewportSize.height].allSatisfy({ $0.isFinite && $0 >= 1 }) else { return nil }
        let columns = Int((contentSize.width / viewportSize.width).rounded(.up))
        let rows = Int((contentSize.height / viewportSize.height).rounded(.up))
        guard columns * rows <= Self.maximumTiles else { return nil }
        self.contentSize = contentSize
        self.viewportSize = viewportSize
        let xs = (0..<columns).map { CGFloat($0) * viewportSize.width }
        let ys = (0..<rows).map { CGFloat($0) * viewportSize.height }
        origins = ys.flatMap { y in xs.map { x in CGPoint(x: x, y: y) } }
    }

    /// Where the page scrolls for `origin`: clamped to its scroll range.
    public func expectedScroll(for origin: CGPoint) -> CGPoint {
        CGPoint(x: min(origin.x, max(0, contentSize.width - viewportSize.width)),
                y: min(origin.y, max(0, contentSize.height - viewportSize.height)))
    }
}

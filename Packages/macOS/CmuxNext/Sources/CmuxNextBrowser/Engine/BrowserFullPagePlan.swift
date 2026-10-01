import CoreGraphics

/// The viewport positions a stitched full-page capture scrolls to, in CSS
/// pixels, row by row. The page clamps the last row and column to its
/// scroll range, so each tile is drawn where the page actually scrolled.
public nonisolated struct BrowserFullPagePlan: Equatable, Sendable {
    /// The old app's ceiling for a full-page capture, in CSS pixels.
    public static let maximumPixels: Double = 100_000_000

    public let contentSize: CGSize
    public let viewportSize: CGSize
    public let origins: [CGPoint]

    /// Nil when a size is empty or not finite, or the page is too large.
    public init?(contentSize: CGSize, viewportSize: CGSize) {
        let sizes = [contentSize.width, contentSize.height, viewportSize.width, viewportSize.height]
        guard sizes.allSatisfy({ $0.isFinite && $0 > 0 }),
              Double(contentSize.width * contentSize.height) <= Self.maximumPixels else { return nil }
        self.contentSize = contentSize
        self.viewportSize = viewportSize
        let xs = stride(from: 0, to: contentSize.width, by: viewportSize.width)
        let ys = stride(from: 0, to: contentSize.height, by: viewportSize.height)
        origins = ys.flatMap { y in xs.map { x in CGPoint(x: x, y: y) } }
    }
}

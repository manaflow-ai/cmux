public import CoreGraphics

/// Where the wallpaper still lies in a page (`rect` of the `cmuxTheme.backdrop` payload,
/// plans/cmux-next/glass-lens-DESIGN.md): the art's aspect-filled rect in the page's CSS px,
/// relative to the page viewport's top-left corner. The art view draws its image aspect-filled
/// and centered (`resizeAspectFill`, like a macOS wallpaper), so the rect usually overhangs the
/// page; the page clips it. The Desktop Wallpaper places it as the screen does (``BackdropArtFit``).
public nonisolated struct GlassBackdropRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The rect of an `imageSize` image aspect-filled into `artFrame`, seen from `pageFrame`.
    ///
    /// - Parameters:
    ///   - imageSize: The art's size; only its aspect ratio matters.
    ///   - artFrame: The art view's frame in window coordinates (bottom-left origin).
    ///   - pageFrame: The web view's frame in window coordinates (bottom-left origin).
    ///   - zoom: The page zoom (`pageZoom` times magnification): one CSS px is `zoom` points.
    ///   - fit: How the art view places the picture (the Desktop Wallpaper follows the screen's
    ///     own Fill, Fit, Stretch or Center); every other background fills.
    ///   - pointsPerPixel: Points per picture pixel, for a centered picture at its own size.
    /// - Returns: Nil when the art or the page has no area, or the zoom is not positive.
    public init?(imageSize: CGSize, artFrame: CGRect, pageFrame: CGRect, zoom: Double,
                 fit: BackdropArtFit = .fill, pointsPerPixel: CGFloat = 1) {
        guard zoom > 0, zoom.isFinite, pageFrame.width > 0, pageFrame.height > 0,
              let image = fit.rect(of: imageSize, in: artFrame, pointsPerPixel: pointsPerPixel) else { return nil }
        func css(_ points: CGFloat) -> Double { (Double(points) / zoom * 100).rounded() / 100 }
        // Window coordinates grow upward; CSS grows downward from the viewport's top edge.
        self.init(x: css(image.minX - pageFrame.minX), y: css(pageFrame.maxY - image.maxY),
                  width: css(image.width), height: css(image.height))
    }

    /// `imageSize` scaled to cover `bounds` and centered on it (Core Animation's
    /// `resizeAspectFill`); nil when either has no area.
    public static func aspectFill(_ imageSize: CGSize, in bounds: CGRect) -> CGRect? {
        BackdropArtFit.fill.rect(of: imageSize, in: bounds)
    }

    /// `{x, y, width, height}` for the page.
    public var json: [String: Double] { ["x": x, "y": y, "width": width, "height": height] }
}

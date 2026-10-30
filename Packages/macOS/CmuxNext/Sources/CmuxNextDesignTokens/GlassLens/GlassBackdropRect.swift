public import CoreGraphics

/// Where the wallpaper still lies in a page (`rect` of the `cmuxTheme.backdrop` payload,
/// plans/cmux-next/glass-lens-DESIGN.md): the art's aspect-filled rect in the page's CSS px,
/// relative to the page viewport's top-left corner. The art view draws its image aspect-filled
/// and centered (`resizeAspectFill`, like a macOS wallpaper), so the rect usually overhangs the
/// page; the page clips it.
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
    /// - Returns: Nil when the art or the page has no area, or the zoom is not positive.
    public init?(imageSize: CGSize, artFrame: CGRect, pageFrame: CGRect, zoom: Double) {
        guard zoom > 0, zoom.isFinite, pageFrame.width > 0, pageFrame.height > 0,
              let image = Self.aspectFill(imageSize, in: artFrame) else { return nil }
        func css(_ points: CGFloat) -> Double { (Double(points) / zoom * 100).rounded() / 100 }
        // Window coordinates grow upward; CSS grows downward from the viewport's top edge.
        self.init(x: css(image.minX - pageFrame.minX), y: css(pageFrame.maxY - image.maxY),
                  width: css(image.width), height: css(image.height))
    }

    /// `imageSize` scaled to cover `bounds` and centered on it (Core Animation's
    /// `resizeAspectFill`); nil when either has no area.
    public static func aspectFill(_ imageSize: CGSize, in bounds: CGRect) -> CGRect? {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// `{x, y, width, height}` for the page.
    public var json: [String: Double] { ["x": x, "y": y, "width": width, "height": height] }
}

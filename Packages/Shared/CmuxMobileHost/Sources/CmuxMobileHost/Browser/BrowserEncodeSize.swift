/// The encode size for a phone viewport (c2-browser-stream.md section 3):
/// the page scaled so its width fills the phone's backing pixels, capped at
/// the page's own backing pixels and `maxLongEdge`, rounded to even.
public struct BrowserEncodeSize: Hashable, Sendable {
    public static let maxLongEdge = 2560.0

    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(pixelWidth: Int, pixelHeight: Int) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// `viewerPixelWidth` is the phone's width in CSS px times its scale
    /// (and times the zoom bucket the phone reported).
    public init(page: BrowserPageGeometry, viewerPixelWidth: Double) {
        let pageWidth = max(page.cssWidth, 1)
        let pageHeight = max(page.cssHeight, 1)
        var width = min(viewerPixelWidth, pageWidth * max(page.backingScale, 1))
        var height = width * pageHeight / pageWidth
        let longEdge = max(width, height)
        if longEdge > Self.maxLongEdge {
            width *= Self.maxLongEdge / longEdge
            height *= Self.maxLongEdge / longEdge
        }
        self.init(pixelWidth: Self.even(width), pixelHeight: Self.even(height))
    }

    private static func even(_ value: Double) -> Int {
        max(2, Int(value.rounded(.down)) & ~1)
    }
}

public import AppKit

/// Adapts an `NSImage` to allocation-free top-left-origin pixel sampling.
public struct BrowserScreenshotBitmapPixelSource: BrowserScreenshotPixelSource {
    /// Pixel dimensions of the normalized bitmap representation.
    public let pixelSize: NSSize
    private let data: Data
    private let bytesPerRow: Int

    /// Creates an sRGB sampler for a drawable image.
    ///
    /// The sampler redraws once into an owned packed-sRGB buffer so every source
    /// representation has the same channel order and color space.
    ///
    /// - Parameter image: Snapshot image to normalize for direct pixel access.
    /// - Returns: `nil` when the image cannot provide a drawable CG representation.
    public init?(image: NSImage) {
        guard let normalized = BrowserScreenshotPixelNormalizer().normalize(image) else {
            return nil
        }
        self.pixelSize = NSSize(
            width: normalized.width,
            height: normalized.height
        )
        self.data = normalized.data
        self.bytesPerRow = normalized.bytesPerRow
    }

    /// Reads one top-left-origin pixel from the owned packed-sRGB buffer.
    ///
    /// - Parameter point: Pixel coordinate to sample.
    /// - Returns: A normalized color, or `nil` when `point` is outside the bitmap.
    public func color(at point: NSPoint) -> BrowserScreenshotRGBA? {
        let x = Int(point.x.rounded(.down))
        let y = Int(point.y.rounded(.down))
        guard x >= 0,
              x < Int(pixelSize.width),
              y >= 0,
              y < Int(pixelSize.height) else {
            return nil
        }
        let offset = y * bytesPerRow + x * 4
        return BrowserScreenshotRGBA(
            red: CGFloat(data[offset]) / 255.0,
            green: CGFloat(data[offset + 1]) / 255.0,
            blue: CGFloat(data[offset + 2]) / 255.0,
            alpha: CGFloat(data[offset + 3]) / 255.0
        )
    }
}

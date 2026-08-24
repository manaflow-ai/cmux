public import AppKit

/// Adapts an `NSImage` to bounded top-left-origin pixel sampling.
public struct BrowserScreenshotBitmapPixelSource: BrowserScreenshotPixelSource {
    /// Pixel dimensions of the snapshot representation.
    public let pixelSize: NSSize
    private let image: CGImage

    /// Creates a bounded sRGB sampler for a drawable image.
    ///
    /// Probe rectangles are redrawn independently so source channel order,
    /// premultiplied alpha, and color-space conversion are normalized without
    /// copying the entire snapshot into a second full-frame buffer.
    ///
    /// - Parameter image: Snapshot image to sample.
    /// - Returns: `nil` when the image cannot provide a drawable CG representation.
    public init?(image: NSImage) {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else {
            return nil
        }
        self.image = cgImage
        self.pixelSize = NSSize(
            width: cgImage.width,
            height: cgImage.height
        )
    }

    /// Normalizes only the requested probe rectangle, then samples its packed bytes.
    public func colors(
        in rect: NSRect,
        stride: Int
    ) -> [BrowserScreenshotRGBA]? {
        guard stride > 0,
              let normalized = BrowserScreenshotPixelNormalizer().normalize(
                  image,
                  topLeftRect: rect
              ) else {
            return nil
        }

        var result: [BrowserScreenshotRGBA] = []
        let columnCount = (normalized.width - 1) / stride + 1
        let rowCount = (normalized.height - 1) / stride + 1
        result.reserveCapacity(columnCount * rowCount)
        for y in Swift.stride(from: 0, to: normalized.height, by: stride) {
            for x in Swift.stride(from: 0, to: normalized.width, by: stride) {
                let offset = y * normalized.bytesPerRow + x * 4
                let alpha = CGFloat(normalized.data[offset + 3]) / 255.0
                let straightColorScale = alpha > 0 ? 1.0 / (255.0 * alpha) : 0
                result.append(BrowserScreenshotRGBA(
                    red: min(1, CGFloat(normalized.data[offset]) * straightColorScale),
                    green: min(1, CGFloat(normalized.data[offset + 1]) * straightColorScale),
                    blue: min(1, CGFloat(normalized.data[offset + 2]) * straightColorScale),
                    alpha: alpha
                ))
            }
        }
        return result
    }
}

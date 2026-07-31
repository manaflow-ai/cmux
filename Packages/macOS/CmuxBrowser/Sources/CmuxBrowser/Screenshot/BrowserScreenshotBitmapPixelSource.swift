public import AppKit

/// Adapts an `NSImage` to allocation-free top-left-origin pixel sampling.
public struct BrowserScreenshotBitmapPixelSource: BrowserScreenshotFrameVerifier.PixelSource {
    /// Pixel dimensions of the normalized bitmap representation.
    public let pixelSize: NSSize
    private let data: Data
    private let bytesPerRow: Int

    private struct NormalizedPixels {
        let data: Data
        let width: Int
        let height: Int
        let bytesPerRow: Int
    }

    /// Creates an sRGB sampler for a drawable image.
    ///
    /// The sampler redraws once into an owned packed-sRGB buffer so every source
    /// representation has the same channel order and color space.
    ///
    /// - Parameter image: Snapshot image to normalize for direct pixel access.
    /// - Returns: `nil` when the image cannot provide a drawable CG representation.
    public init?(image: NSImage) {
        guard let normalized = Self.normalizedPixels(from: image) else {
            return nil
        }
        self.pixelSize = NSSize(
            width: normalized.width,
            height: normalized.height
        )
        self.data = normalized.data
        self.bytesPerRow = normalized.bytesPerRow
    }

    /// Redraws any AppKit/CG image layout into one owned packed-sRGB buffer.
    private static func normalizedPixels(from image: NSImage) -> NormalizedPixels? {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else {
            return nil
        }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0,
              height > 0,
              width <= Int.max / 4 else {
            return nil
        }
        let bytesPerRow = width * 4
        guard height <= Int.max / bytesPerRow,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        var data = Data(count: bytesPerRow * height)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        let didDraw = data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo
                  ) else {
                return false
            }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(
                cgImage,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return true
        }
        guard didDraw else {
            return nil
        }
        return NormalizedPixels(
            data: data,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )
    }

    /// Reads one top-left-origin pixel from the owned packed-sRGB buffer.
    ///
    /// - Parameter point: Pixel coordinate to sample.
    /// - Returns: A normalized color, or `nil` when `point` is outside the bitmap.
    public func color(at point: NSPoint) -> BrowserScreenshotFrameVerifier.RGBA? {
        let x = Int(point.x.rounded(.down))
        let y = Int(point.y.rounded(.down))
        guard x >= 0,
              x < Int(pixelSize.width),
              y >= 0,
              y < Int(pixelSize.height) else {
            return nil
        }
        let offset = y * bytesPerRow + x * 4
        return BrowserScreenshotFrameVerifier.RGBA(
            red: CGFloat(data[offset]) / 255.0,
            green: CGFloat(data[offset + 1]) / 255.0,
            blue: CGFloat(data[offset + 2]) / 255.0,
            alpha: CGFloat(data[offset + 3]) / 255.0
        )
    }
}

public import AppKit

/// Adapts an `NSImage` to bounded top-left-origin pixel sampling.
public struct BrowserScreenshotBitmapPixelSource: BrowserScreenshotPixelSource {
    /// Pixel dimensions of the selected bitmap representation.
    public let pixelSize: NSSize
    private let bitmap: NSBitmapImageRep

    /// Creates an on-demand sRGB sampler for a drawable image.
    ///
    /// Sampling through `NSBitmapImageRep` lets AppKit handle source channel
    /// order, premultiplied alpha, and color-space conversion without copying
    /// the entire snapshot into a second full-frame buffer.
    ///
    /// - Parameter image: Snapshot image to sample.
    /// - Returns: `nil` when the image cannot provide a bitmap representation.
    public init?(image: NSImage) {
        let candidates = image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .filter { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }
            .sorted {
                Double($0.pixelsWide) * Double($0.pixelsHigh)
                    > Double($1.pixelsWide) * Double($1.pixelsHigh)
            }
        let selected: NSBitmapImageRep
        if let candidate = candidates.first {
            selected = candidate
        } else {
            var proposedRect = NSRect(origin: .zero, size: image.size)
            guard let cgImage = image.cgImage(
                forProposedRect: &proposedRect,
                context: nil,
                hints: nil
            ) else {
                return nil
            }
            selected = NSBitmapImageRep(cgImage: cgImage)
        }
        self.bitmap = selected
        self.pixelSize = NSSize(
            width: selected.pixelsWide,
            height: selected.pixelsHigh
        )
    }

    /// Reads one top-left-origin pixel and converts it to straight-alpha sRGB.
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
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
            return nil
        }
        return BrowserScreenshotRGBA(
            red: color.redComponent,
            green: color.greenComponent,
            blue: color.blueComponent,
            alpha: color.alphaComponent
        )
    }
}

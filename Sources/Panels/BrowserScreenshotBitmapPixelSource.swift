import AppKit

/// Adapts an `NSImage` to sparse top-left-origin pixel sampling.
struct BrowserScreenshotBitmapPixelSource: BrowserScreenshotFrameVerifier.PixelSource {
    let pixelSize: NSSize
    private let bitmap: NSBitmapImageRep

    init?(image: NSImage) {
        let candidate = image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .max {
                $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
            }
        if let candidate {
            self.bitmap = candidate
        } else {
            var proposedRect = NSRect(origin: .zero, size: image.size)
            guard let cgImage = image.cgImage(
                forProposedRect: &proposedRect,
                context: nil,
                hints: nil
            ) else {
                return nil
            }
            self.bitmap = NSBitmapImageRep(cgImage: cgImage)
        }
        guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else {
            return nil
        }
        self.pixelSize = NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
    }

    func color(at point: NSPoint) -> BrowserScreenshotFrameVerifier.RGBA? {
        let x = Int(point.x.rounded(.down))
        let topY = Int(point.y.rounded(.down))
        let y = bitmap.pixelsHigh - 1 - topY
        guard x >= 0,
              x < bitmap.pixelsWide,
              y >= 0,
              y < bitmap.pixelsHigh,
              let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
            return nil
        }
        return BrowserScreenshotFrameVerifier.RGBA(
            red: color.redComponent,
            green: color.greenComponent,
            blue: color.blueComponent,
            alpha: color.alphaComponent
        )
    }
}

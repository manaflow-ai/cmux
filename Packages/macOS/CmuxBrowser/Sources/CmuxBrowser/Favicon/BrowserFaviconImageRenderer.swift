public import Foundation
import AppKit

/// Renders raw favicon image bytes into a square, aspect-fit PNG suitable for display.
///
/// The renderer decodes the supplied bytes with `NSImage`, clamps the requested edge length to
/// the 16…128 px range, then draws the image aspect-fit and pixel-aligned into a transparent
/// `NSBitmapImageRep` before re-encoding as PNG. It is `@MainActor` because it touches the
/// AppKit drawing stack (`NSGraphicsContext`, `NSImage.draw`); it holds no state, so callers can
/// construct one wherever they need it.
@MainActor
public struct BrowserFaviconImageRenderer {
    /// Creates a renderer. The type is stateless; the initializer exists so callers hold a value
    /// rather than reaching for a static utility namespace.
    public init() {}

    /// Decodes `raw` and re-encodes it as an aspect-fit square PNG.
    ///
    /// - Parameters:
    ///   - raw: The original favicon bytes (any format `NSImage` can decode).
    ///   - targetPx: The desired square edge length in pixels; clamped to 16…128.
    /// - Returns: PNG-encoded bytes of the rendered square, or `nil` if the input cannot be
    ///   decoded or a bitmap context cannot be created.
    public func pngData(from raw: Data, targetPx: Int) -> Data? {
        guard let image = NSImage(data: raw) else { return nil }

        let px = max(16, min(128, targetPx))
        let size = NSSize(width: px, height: px)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: px,
            pixelsHigh: px,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
        ctx?.imageInterpolation = .high
        ctx?.shouldAntialias = true
        NSGraphicsContext.current = ctx

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        // Aspect-fit into the target square.
        let srcSize = image.size
        let scale = min(size.width / max(1, srcSize.width), size.height / max(1, srcSize.height))
        let drawSize = NSSize(width: srcSize.width * scale, height: srcSize.height * scale)
        let drawOrigin = NSPoint(x: (size.width - drawSize.width) / 2.0, y: (size.height - drawSize.height) / 2.0)
        // Align to integral pixels to avoid soft edges at small sizes.
        let drawRect = NSRect(
            x: round(drawOrigin.x),
            y: round(drawOrigin.y),
            width: round(drawSize.width),
            height: round(drawSize.height)
        )

        image.draw(
            in: drawRect,
            from: NSRect(origin: .zero, size: srcSize),
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        return rep.representation(using: .png, properties: [:])
    }
}

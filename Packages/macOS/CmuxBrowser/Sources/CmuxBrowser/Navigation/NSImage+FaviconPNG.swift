public import AppKit

extension NSImage {
    /// Render this image into a normalized, aspect-fit square PNG for the browser tab/sidebar.
    ///
    /// The browser navigation delegate downloads a page's favicon (arbitrary format and
    /// dimensions), decodes it into an `NSImage`, then asks for a fixed-size, aspect-fit,
    /// transparent-padded square PNG so the icon draws crisply at small sizes without
    /// upscaling blur.
    ///
    /// `targetPx` is clamped to `16...128` pixels. The image is scaled to fit inside the
    /// target square (never cropped), centered, and aligned to integral pixels with
    /// high-quality interpolation and antialiasing. Returns `nil` when the bitmap context
    /// cannot be created.
    ///
    /// Drawing touches AppKit graphics state, so this runs on the main actor.
    @MainActor
    public func faviconPNGData(targetPx: Int) -> Data? {
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
        let srcSize = self.size
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

        draw(
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

public import AppKit

/// Measures where an image's ink sits horizontally (alpha over 0.3), so the top row spaces glyphs by
/// what the eye sees rather than by their images' padding (``TopRowSpacing``). Results are cached
/// per image instance: the band measures again only when a density or icon change draws a new image.
@MainActor
public final class GlyphInkMeasure {
    private var cache: [ObjectIdentifier: (image: NSImage, glyph: TopRowSpacing.Glyph)] = [:]

    public init() {}

    /// The glyph's image width and ink extent; the full image when it draws nothing measurable.
    /// - Parameter image: The button's image.
    /// - Returns: Its ``TopRowSpacing/Glyph``.
    public func glyph(of image: NSImage) -> TopRowSpacing.Glyph {
        let key = ObjectIdentifier(image)
        if let hit = cache[key], hit.image === image { return hit.glyph }
        let glyph = Self.measure(image)
        if cache.count > 16 { cache.removeAll() }
        cache[key] = (image, glyph)
        return glyph
    }

    private static func measure(_ image: NSImage) -> TopRowSpacing.Glyph {
        let size = image.size, scale: CGFloat = 4
        let whole = TopRowSpacing.Glyph(imageWidth: size.width, ink: 0...max(0, size.width))
        let (w, h) = (Int((size.width * scale).rounded(.up)), Int((size.height * scale).rounded(.up)))
        guard w > 0, h > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return whole }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return whole }
        var minX = Int.max, maxX = -1
        for y in 0..<h {
            let row = data + y * rep.bytesPerRow
            for x in 0..<w where row[x * 4 + 3] > 76 { // alpha > 0.3
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        guard maxX >= minX else { return whole }
        return TopRowSpacing.Glyph(imageWidth: size.width, ink: (CGFloat(minX) / scale)...(CGFloat(maxX + 1) / scale))
    }
}

extension GlyphInkMeasure {
    /// The top-row band's buttons laid out from their images' ink, `gap` apart (``TopRowSpacing/slots(side:gap:glyphs:)``).
    /// - Parameter images: Each button's image, in band order (nil: an empty glyph).
    /// - Parameter gap: The ink gap between consecutive glyphs.
    /// - Returns: The band's ``TopRowSpacing/Slots``.
    public func slots(for images: [NSImage?], gap: CGFloat) -> TopRowSpacing.Slots {
        let glyphs = images.map { $0.map(glyph(of:)) ?? TopRowSpacing.Glyph(imageWidth: 0, ink: 0...0) }
        return TopRowSpacing.slots(side: TopRowSpacing.buttonSide, gap: gap, glyphs: glyphs)
    }
}

extension TopRowSpacing.Slots {
    /// Each button's frame at `presence` (0 collapsed at the band's origin, 1 full), centered in a band `height` tall:
    /// every frame and gap scales with it, so the band closes to 0 width with no jump.
    /// - Parameter presence: How much of the band shows.
    /// - Parameter height: The band's height.
    /// - Returns: The buttons' frames, in band order.
    public func frames(presence: CGFloat, height: CGFloat) -> [NSRect] {
        let side = TopRowSpacing.buttonSide
        return frames.map { NSRect(x: $0.x * presence, y: (height - side) / 2, width: $0.width * presence, height: side) }
    }
}

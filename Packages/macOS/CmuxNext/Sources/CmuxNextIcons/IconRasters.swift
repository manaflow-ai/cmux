import AppKit
import CmuxNextCompat

/// One bitmap per drawn glyph, shared by every image of it (REOPEN-F7 part A2; Chrome's shared image cache).
///
/// `NSImage.icon` used to return a drawing-handler image, and AppKit keeps one raster per image instance: N views
/// showing the same glyph rasterized it N times on the main thread, in the first display pass of a reopened window
/// (37-43 ms of AppKit work before the first frame). Each key here is drawn once, from any thread, and every image
/// of it wraps the same bitmap. Chrome glyphs are templates (black ink, tinted by their view), so the light/dark
/// appearance is not part of a key; the drawing (pack layers or SF Symbol), the side and the scale are.
nonisolated final class IconRasters: Sendable {
    /// The app-wide cache.
    static let shared = IconRasters()

    /// The scales a chrome glyph is drawn at: every Mac display is 1x or 2x.
    static let scales: [CGFloat] = [1, 2]

    /// What is drawn: the icon's name and style, or the SF Symbol it stands for. The pack and its family overlay are
    /// fixed before the first icon draws (`IconPack.useOverlay`), so a name and style always resolve to one drawing.
    struct Glyph: Hashable {
        let name: String
        let style: IconStyle
        let symbol: String?
    }

    struct Key: Hashable {
        let glyph: Glyph
        let side: CGFloat
        let scale: CGFloat
    }

    private let bitmaps = Mutex<[Key: CGImage]>([:])

    /// The bitmap of `glyph` at `side` points and `scale`, drawn the first time it is asked for (`resolve` gives its
    /// drawing then).
    func bitmap(_ glyph: Glyph, side: CGFloat, scale: CGFloat, resolve: () -> IconResolution) -> CGImage? {
        let key = Key(glyph: glyph, side: side, scale: scale)
        if let drawn = bitmaps.withLock({ $0[key] }) { return drawn }
        // Drawn outside the lock: two threads may draw one key at once; the first stored wins, both are equal.
        guard let drawn = Self.draw(resolve(), side: side, scale: scale) else { return nil }
        return bitmaps.withLock { stored in
            if let first = stored[key] { return first }
            stored[key] = drawn
            return drawn
        }
    }

    /// A template image of `glyph` at `side` points: one bitmap representation per scale, each the shared bitmap.
    /// Every call returns its own image, so a caller that sets its size or description changes no other.
    func image(_ glyph: Glyph, side: CGFloat, resolve: () -> IconResolution) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side))
        for scale in Self.scales {
            guard let bitmap = bitmap(glyph, side: side, scale: scale, resolve: resolve) else { continue }
            let rep = NSBitmapImageRep(cgImage: bitmap)
            rep.size = NSSize(width: side, height: side)
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        return image
    }

    /// Draws `drawing` in black on a clear `side` x `side` point square at `scale`.
    private static func draw(_ drawing: IconResolution, side: CGFloat, scale: CGFloat) -> CGImage? {
        let pixels = Int((side * scale).rounded())
        guard pixels > 0, let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        switch drawing {
        case .drawing(let layers):
            // `drawIcon` draws y-down.
            context.translateBy(x: 0, y: CGFloat(pixels))
            context.scaleBy(x: 1, y: -1)
            context.drawIcon(layers, in: rect, grid: IconPack.bundled.grid, ink: CGColor(gray: 0, alpha: 1))
        case .system(let symbol):
            // Lay out like a pack icon: the symbol fitted and centered in the square, keeping its proportions.
            let configuration = NSImage.SymbolConfiguration(pointSize: side, weight: .regular)
            guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration),
                  glyph.size.width > 0, glyph.size.height > 0 else { return context.makeImage() }
            context.scaleBy(x: scale, y: scale)
            let fit = min(side / glyph.size.width, side / glyph.size.height)
            let size = NSSize(width: glyph.size.width * fit, height: glyph.size.height * fit)
            let box = NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height)
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            glyph.draw(in: box)
            NSGraphicsContext.current = previous
        }
        return context.makeImage()
    }
}

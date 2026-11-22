import AppKit
import CoreText

/// One emoji drawn whole inside its square. The view measures the glyph's
/// real ink at the size and pixel scale it draws (Core Text's image bounds are
/// smaller than a color emoji's bitmap, and the emoji font's small strikes are
/// padded differently from its large ones), then sizes and centers that ink in
/// the box. An NSTextField label clipped it instead: its cell insets and line
/// box are narrower than a color emoji at the icon size, so the face lost its
/// top and left edge.
final class SidebarEmojiGlyphView: NSView {
    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }
    /// The share of the box the ink may fill, so it never touches the edge
    /// (less on a color chip, so the chip shows around it).
    var fill: CGFloat = 0.86 { didSet { if fill != oldValue { needsDisplay = true } } }

    private struct Key: Hashable { let text: String; let size: CGFloat; let pixelScale: CGFloat }
    /// Ink rect of an emoji at a point size and pixel scale, relative to its baseline origin.
    private static var inkCache: [Key: CGRect] = [:]

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let target = min(bounds.width, bounds.height) * fill
        let pixelScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard target > 0, let (size, ink) = Self.fit(text, target: target, pixelScale: pixelScale) else { return }
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: bounds.midX - ink.midX, y: bounds.midY - ink.midY)
        CTLineDraw(Self.line(text, size: size), context)
        context.restoreGState()
    }

    /// The point size whose ink fills `target` points, and that ink. Two steps: the
    /// strike can change between sizes, so the second size is measured again and,
    /// if its ink still overshoots, shrunk once more by the remaining ratio.
    static func fit(_ text: String, target: CGFloat, pixelScale: CGFloat) -> (CGFloat, CGRect)? {
        var size = target
        var ink: CGRect?
        for _ in 0..<3 {
            guard let measured = Self.ink(text, size: size, pixelScale: pixelScale),
                  measured.width > 0, measured.height > 0 else { return nil }
            ink = measured
            let extent = max(measured.width, measured.height)
            if abs(extent - target) <= 0.5 / pixelScale { break }
            size = (size * target / extent * 4).rounded(.down) / 4
        }
        guard var found = ink else { return nil }
        if max(found.width, found.height) > target + 0.5 / pixelScale,
           let smaller = Self.ink(text, size: size * target / max(found.width, found.height), pixelScale: pixelScale) {
            size *= target / max(found.width, found.height)
            found = smaller
        }
        return (size, found)
    }

    private static func line(_ text: String, size: CGFloat) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size)]))
    }

    /// The emoji's ink at `size` points: drawn at `pixelScale` into an RGBA bitmap and scanned.
    static func ink(_ text: String, size: CGFloat, pixelScale: CGFloat) -> CGRect? {
        let key = Key(text: text, size: size, pixelScale: pixelScale)
        if let cached = inkCache[key] { return cached }
        let side = Int(ceil(size * 3 * pixelScale)), origin = size
        guard side > 0,
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: pixelScale, y: pixelScale)
        context.textPosition = CGPoint(x: origin, y: origin)
        CTLineDraw(line(text, size: size), context)
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var minX = side, minY = side, maxX = -1, maxY = -1
        for row in 0..<side {
            for column in 0..<side where bytes[(row * side + column) * 4 + 3] > 38 {
                minX = min(minX, column); maxX = max(maxX, column)
                minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        guard maxX >= 0 else { return nil }
        // CGContext memory rows run top-down; convert to points, bottom-up, relative to the origin.
        let found = CGRect(x: CGFloat(minX) / pixelScale - origin,
                           y: CGFloat(side - 1 - maxY) / pixelScale - origin,
                           width: CGFloat(maxX - minX + 1) / pixelScale,
                           height: CGFloat(maxY - minY + 1) / pixelScale)
        inkCache[key] = found
        return found
    }
}

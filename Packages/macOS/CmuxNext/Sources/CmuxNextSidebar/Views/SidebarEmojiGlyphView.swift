import AppKit
import CoreText

/// One emoji drawn whole inside its square: the view measures the glyph's
/// real ink once (rasterized at a reference size; Core Text's image bounds
/// are smaller than a color emoji's bitmap) and scales and centers that ink
/// in the box. An NSTextField label clipped it instead: its cell insets and
/// line box are narrower than a color emoji at the icon size, so the face lost
/// its top and left edge.
final class SidebarEmojiGlyphView: NSView {
    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }
    /// The share of the box the ink may fill, so it never touches the edge
    /// (less on a color chip, so the chip shows around it).
    var fill: CGFloat = 0.86 { didSet { if fill != oldValue { needsDisplay = true } } }

    private static let reference: CGFloat = 64
    /// Ink rect of each emoji at `reference` points, relative to its baseline origin.
    private static var inkCache: [String: CGRect] = [:]

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty, let context = NSGraphicsContext.current?.cgContext,
              let ink = Self.ink(text), ink.width > 0, ink.height > 0 else { return }
        let target = min(bounds.width, bounds.height) * fill
        guard target > 0 else { return }
        let scale = target / max(ink.width, ink.height)
        let line = Self.line(text, size: Self.reference * scale)
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: bounds.midX - ink.midX * scale, y: bounds.midY - ink.midY * scale)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func line(_ text: String, size: CGFloat) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size)]))
    }

    /// The emoji's ink at `reference` points: drawn into an alpha bitmap and scanned.
    static func ink(_ text: String) -> CGRect? {
        if let cached = inkCache[text] { return cached }
        let side = Int(reference * 3), origin = reference
        var pixels = [UInt8](repeating: 0, count: side * side)
        let found: CGRect? = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
            context.textPosition = CGPoint(x: origin, y: origin)
            CTLineDraw(line(text, size: reference), context)
            let bytes = buffer.bindMemory(to: UInt8.self)
            var minX = side, minY = side, maxX = -1, maxY = -1
            for row in 0..<side {
                for column in 0..<side where bytes[row * side + column] > 24 {
                    minX = min(minX, column); maxX = max(maxX, column)
                    minY = min(minY, row); maxY = max(maxY, row)
                }
            }
            guard maxX >= 0 else { return nil }
            // Bitmap rows run top-down; convert to a bottom-up rect relative to the origin.
            return CGRect(x: CGFloat(minX) - origin, y: CGFloat(side - 1 - maxY) - origin,
                          width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
        }
        if let found { inkCache[text] = found }
        return found
    }
}

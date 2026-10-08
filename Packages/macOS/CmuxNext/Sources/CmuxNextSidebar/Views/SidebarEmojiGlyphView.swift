import AppKit
import CoreText

/// One emoji drawn whole inside its square: Core Text measures the glyph's
/// ink and the view scales and centers that ink in the box. An NSTextField
/// label clipped it instead: its cell insets and line box are narrower than a
/// color emoji at the icon size, so the face lost its top and left edge.
final class SidebarEmojiGlyphView: NSView {
    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }
    /// The share of the box the ink may fill, so it never touches the edge
    /// (less on a color chip, so the chip shows around it).
    var fill: CGFloat = 0.86 { didSet { if fill != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let target = min(bounds.width, bounds.height) * fill
        guard target > 0 else { return }
        // Measure at a reference size, then scale: emoji ink grows linearly with the point size.
        let reference: CGFloat = 64
        let measured = Self.line(text, size: reference)
        let ink = CTLineGetImageBounds(measured, context)
        guard ink.width > 0, ink.height > 0 else { return }
        let size = reference * target / max(ink.width, ink.height)
        let line = Self.line(text, size: size)
        let box = CTLineGetImageBounds(line, context)
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: bounds.midX - box.midX, y: bounds.midY - box.midY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func line(_ text: String, size: CGFloat) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size)]))
    }
}

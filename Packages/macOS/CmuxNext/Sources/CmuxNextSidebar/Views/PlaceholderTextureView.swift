import AppKit
import CoreText

/// What a placeholder row draws where its title goes: the tonal bar, or
/// with `usesBraille` (Debug Settings, off by default) the bar's shape as a
/// quieter texture, a static run of braille cells (`⣿`) in the bar's color,
/// as tall as the bar and as wide as the bar would be. When no installed
/// font draws braille (Core Text would show the LastResort box), the bar. Never animates, takes no clicks and is no
/// accessibility element: the section header says the machine connects.
final class PlaceholderTextureView: NSView {
    /// The cell repeated across the width: all eight dots.
    static let cell = "⣿"

    /// The bar's color, which the cells use too (set inside the row's
    /// `performWithTheme`).
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    /// The bar's height; the cells' dots span the same height.
    var inkHeight: CGFloat = 0 {
        didSet {
            guard inkHeight != oldValue else { return }
            resolveGlyphFont()
            needsDisplay = true
        }
    }

    /// Draws braille cells instead of the bar (when a font has them).
    var usesBraille = false {
        didSet {
            guard usesBraille != oldValue else { return }
            resolveGlyphFont()
            needsDisplay = true
        }
    }
    /// The font that draws the cells; nil when braille is off or no font
    /// has the cell. Resolved only while braille is on, so the default
    /// bar never asks Core Text for a fallback face.
    private(set) var glyphFont: NSFont?
    /// What `draw` uses: braille cells, else the tonal bar.
    var drawsBraille: Bool { glyphFont != nil }

    private func resolveGlyphFont() {
        glyphFont = usesBraille ? Self.brailleFont(inkHeight: inkHeight) : nil
    }

    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// A monospaced font whose `cell` is `inkHeight` tall and that really
    /// draws it: the system monospaced face, or the face Core Text falls
    /// back to for braille. Nil when only LastResort would draw it.
    static func brailleFont(inkHeight: CGFloat) -> NSFont? {
        guard inkHeight > 0 else { return nil }
        let reference: CGFloat = 100
        guard let probe = resolvedFont(size: reference) else { return nil }
        let ink = inkBounds(font: probe)
        guard ink.height > 0 else { return nil }
        return resolvedFont(size: reference * inkHeight / ink.height)
    }

    private static func resolvedFont(size: CGFloat) -> NSFont? {
        let base = NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
        let resolved = CTFontCreateForString(base, cell as CFString, CFRange(location: 0, length: (cell as NSString).length))
        guard CTFontCopyPostScriptName(resolved) as String != "LastResort" else { return nil }
        var characters = Array(cell.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(resolved, &characters, &glyphs, characters.count), !glyphs.contains(0) else { return nil }
        return resolved as NSFont
    }

    /// The cell's ink, relative to its baseline (y up).
    private static func inkBounds(font: NSFont) -> CGRect {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: cell, attributes: [.font: font]))
        return CTLineGetImageBounds(line, nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let glyphFont {
            let attributes: [NSAttributedString.Key: Any] = [.font: glyphFont, .foregroundColor: color]
            let advance = NSAttributedString(string: Self.cell, attributes: attributes).size().width
            guard advance > 0 else { return }
            let count = Int(bounds.width / advance)
            guard count > 0 else { return }
            let text = NSAttributedString(string: String(repeating: Self.cell, count: count), attributes: attributes)
            // The dots centered where the bar's middle would be.
            let ink = Self.inkBounds(font: glyphFont)
            text.draw(at: NSPoint(x: 0, y: (bounds.height / 2 - glyphFont.ascender + ink.midY).rounded()))
        } else {
            let height = inkHeight
            let bar = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
            color.setFill()
            NSBezierPath(roundedRect: bar, xRadius: height / 2, yRadius: height / 2).fill()
        }
    }
}

import AppKit
import CoreText

/// What a placeholder row draws where its title goes: a static, dim run of
/// braille cells (`⣿`), the texture a terminal prints, as wide as the row
/// gives it. When no installed font draws braille (Core Text would show the
/// LastResort box), a plain tonal bar instead. Never animates, takes no
/// clicks and is no accessibility element: the section header says the
/// machine connects.
final class PlaceholderTextureView: NSView {
    /// The cell repeated across the width: all eight dots.
    static let cell = "⣿"

    /// The glyph color (set inside the row's `performWithTheme`).
    var glyphColor: NSColor = .clear { didSet { needsDisplay = true } }
    /// The fallback bar's color (set inside the row's `performWithTheme`).
    var barColor: NSColor = .clear { didSet { needsDisplay = true } }
    /// The row title's size; the cells use a monospaced face at that size.
    var pointSize: CGFloat = 0 {
        didSet {
            guard pointSize != oldValue else { return }
            glyphFont = Self.brailleFont(size: pointSize)
            needsDisplay = true
        }
    }

    /// The font that draws the cells; nil draws the tonal bar.
    private(set) var glyphFont: NSFont?

    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// A monospaced font at `size` that really draws `cell`: the system
    /// monospaced face, or the face Core Text falls back to for braille.
    /// Nil when only LastResort would draw it.
    static func brailleFont(size: CGFloat) -> NSFont? {
        guard size > 0 else { return nil }
        let base = NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
        let resolved = CTFontCreateForString(base, cell as CFString, CFRange(location: 0, length: (cell as NSString).length))
        guard CTFontCopyPostScriptName(resolved) as String != "LastResort" else { return nil }
        var characters = Array(cell.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(resolved, &characters, &glyphs, characters.count), !glyphs.contains(0) else { return nil }
        return resolved as NSFont
    }

    override func draw(_ dirtyRect: NSRect) {
        if let glyphFont {
            let attributes: [NSAttributedString.Key: Any] = [.font: glyphFont, .foregroundColor: glyphColor]
            let advance = NSAttributedString(string: Self.cell, attributes: attributes).size().width
            guard advance > 0 else { return }
            let count = Int(bounds.width / advance)
            guard count > 0 else { return }
            let text = NSAttributedString(string: String(repeating: Self.cell, count: count), attributes: attributes)
            let height = text.size().height
            text.draw(at: NSPoint(x: 0, y: ((bounds.height - height) / 2).rounded()))
        } else {
            let height = SidebarStyle.placeholderBarHeight
            let bar = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
            barColor.setFill()
            NSBezierPath(roundedRect: bar, xRadius: height / 2, yRadius: height / 2).fill()
        }
    }
}

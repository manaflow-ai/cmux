public import AppKit

/// The AppKit label whose text color blends on a theme change (I5, cx-8w027.3, cx-8w027.12).
///
/// It is an `NSTextField` in every way but the ink: layout, intrinsic size, wrapping, line
/// count, truncation, alignment and accessibility are the field's own, and its own cell draws
/// the text, so the glyphs are where and how an `NSTextField` draws them. The cell draws once,
/// in black, as the mask of a fill layer whose `backgroundColor` is ``textColor``: the color is
/// a layer color the render server blends from the color on screen (`ThemeRepaint`), and a
/// color change draws no glyphs. The glyphs draw again only when what they show changes (text,
/// font, size, scale, line settings).
///
/// One text color per label: per-run colors of an attributed string draw in ``textColor``
/// (keep an `NSTextField` for text with its own run colors).
open class ChromeLabel: NSTextField {
    /// The text color, masked by ``glyphs``.
    private let fill = CALayer()
    private let glyphs = LabelGlyphLayer()
    /// What ``glyphs`` shows now; a different one draws them again.
    private var drawn: Ink?

    public convenience init(font: NSFont) {
        self.init(labelWithString: "")
        self.font = font
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        cell?.truncatesLastVisibleLine = true
    }

    override open var wantsUpdateLayer: Bool { true }

    // Each of these changes the glyphs or their color: `updateLayer` sorts out which.
    override open var stringValue: String { didSet { needsDisplay = true } }
    override open var attributedStringValue: NSAttributedString { didSet { needsDisplay = true } }
    override open var font: NSFont? { didSet { needsDisplay = true } }
    override open var textColor: NSColor? { didSet { needsDisplay = true } }
    override open var alignment: NSTextAlignment { didSet { needsDisplay = true } }
    override open var lineBreakMode: NSLineBreakMode { didSet { needsDisplay = true } }

    override open func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override open func updateLayer() {
        guard let layer else { return }
        if fill.superlayer !== layer {
            let still: [String: any CAAction] = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(),
                                                 "contents": NSNull(), "frame": NSNull(), "contentsScale": NSNull(),
                                                 "hidden": NSNull()]
            fill.actions = still
            glyphs.actions = still
            glyphs.label = self
            fill.mask = glyphs
            layer.addSublayer(fill)
        }
        // AppKit runs this with the view's appearance as the drawing appearance, as it does
        // for `draw(_:)`: dynamic colors resolve the way the field's own drawing resolved them.
        layer.backgroundColor = drawsBackground ? backgroundColor?.cgColor : nil
        fill.backgroundColor = textColor?.cgColor
        // A selectable label being selected: the field editor draws the text.
        fill.isHidden = currentEditor() != nil
        let scale = window?.backingScaleFactor ?? layer.contentsScale
        if fill.frame != layer.bounds || glyphs.contentsScale != scale {
            fill.frame = layer.bounds
            glyphs.frame = fill.bounds
            glyphs.contentsScale = scale
        }
        let ink = Ink(text: inkText(), size: bounds.size, scale: scale, lines: maximumNumberOfLines,
                      lineBreak: lineBreakMode, alignment: alignment,
                      truncates: cell?.truncatesLastVisibleLine ?? false, wraps: cell?.wraps ?? false)
        if ink != drawn {
            drawn = ink
            glyphs.setNeedsDisplay()
        }
    }

    override open func becomeFirstResponder() -> Bool {
        defer { needsDisplay = true }
        return super.becomeFirstResponder()
    }

    override open func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        needsDisplay = true
    }

    override open func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    /// The field's text with every run in black: the glyph coverage, whatever the color.
    private func inkText() -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: attributedStringValue)
        let all = NSRange(location: 0, length: text.length)
        text.removeAttribute(.foregroundColor, range: all)
        text.addAttribute(.foregroundColor, value: NSColor.black, range: all)
        return text
    }

    /// Draws the glyph coverage: a copy of the field's cell, in black, without a background.
    fileprivate func drawGlyphs(in ctx: CGContext, flipped: Bool) {
        guard let drawn, drawn.text.length > 0, let ink = cell?.copy() as? NSTextFieldCell else { return }
        ink.drawsBackground = false
        ink.textColor = .black
        ink.attributedStringValue = drawn.text
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // The field draws in flipped coordinates; a layer context is unflipped unless its
        // geometry is.
        if !flipped {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        // What AppKit enables for label text (a transparent layer leaves it off).
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        ink.draw(withFrame: bounds, in: self)
    }

    /// What the glyphs show (not their color).
    private struct Ink: Equatable {
        var text: NSAttributedString
        var size: CGSize
        var scale: CGFloat
        var lines: Int
        var lineBreak: NSLineBreakMode
        var alignment: NSTextAlignment
        var truncates: Bool
        var wraps: Bool
    }
}

/// ``ChromeLabel``'s glyph coverage: the mask of its fill layer.
nonisolated private final class LabelGlyphLayer: CALayer {
    weak var label: ChromeLabel?

    override func draw(in ctx: CGContext) {
        let flipped = contentsAreFlipped()
        // main-proof: AppKit displays the layers of a view tree on the main thread, in its commit.
        MainActor.assumeIsolated { label?.drawGlyphs(in: ctx, flipped: flipped) }
    }
}

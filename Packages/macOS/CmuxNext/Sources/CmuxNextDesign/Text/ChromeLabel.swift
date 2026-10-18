public import AppKit

/// The AppKit label whose text color blends on a theme change (I5, cx-8w027.3, cx-8w027.12).
///
/// It is an `NSTextField` in every way but the ink: layout, intrinsic size, wrapping, line
/// count, truncation, alignment and accessibility are the field's own, and its own cell draws
/// the text, so the glyphs are where and how an `NSTextField` draws them. The cell draws once
/// through ``GlyphMask`` (the drawing ``ChromeTextLayer`` uses too), in the text color, as the
/// mask of a fill layer whose `backgroundColor` is ``textColor``: the color is a layer color the
/// render server blends from the color on screen (`ThemeRepaint`). The glyphs draw again only
/// when what they show changes (text, font, size, scale, line settings) or a color change moves
/// the ink to another stem weight (``GlyphMask/weight(of:)``), so they keep an `NSTextField`'s
/// weight in every theme.
///
/// One text color per label: per-run colors of an attributed string draw in ``textColor``
/// (keep an `NSTextField` for text with its own run colors).
open class ChromeLabel: NSTextField {
    /// The text color, masked by ``glyphs``.
    private let fill = CALayer()
    private let glyphs = CALayer()
    /// What ``glyphs`` shows now; a different one draws them again.
    private var drawn: Ink?

    public convenience init(font: NSFont) {
        self.init(labelWithString: "")
        self.font = font
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        cell?.truncatesLastVisibleLine = true
    }

    /// An editable field draws the stock way, so it keeps all of `NSTextField`; only its color
    /// does not blend. A selectable label keeps selection and copy: while it is selected its field
    /// editor draws the text (and the selection), and the glyphs hide.
    override open var wantsUpdateLayer: Bool { !isEditable }
    override open var isEditable: Bool { didSet { inkModeDidChange() } }

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
            fill.mask = glyphs
            layer.addSublayer(fill)
        }
        // AppKit runs this with the view's appearance as the drawing appearance, as it does
        // for `draw(_:)`: dynamic colors resolve the way the field's own drawing resolved them.
        layer.backgroundColor = drawsBackground ? backgroundColor?.cgColor : nil
        fill.backgroundColor = textColor?.cgColor
        // Selected (a selectable label): the field editor draws the text; editable: AppKit does.
        fill.isHidden = !wantsUpdateLayer || currentEditor() != nil
        hideStockText()
        let scale = window?.backingScaleFactor ?? layer.contentsScale
        if fill.frame != layer.bounds { fill.frame = layer.bounds }
        let color = textColor?.cgColor
        let ink = Ink(text: inkText(), size: bounds.size, scale: scale, weight: GlyphMask.weight(of: color),
                      lines: maximumNumberOfLines, lineBreak: lineBreakMode, alignment: alignment,
                      truncates: cell?.truncatesLastVisibleLine ?? false, wraps: cell?.wraps ?? false)
        if ink != drawn {
            drawn = ink
            glyphs.contents = glyphImage(ink, color: color)
            // As the field's backing store sits: the image at its own pixel size, top edge on top.
            GlyphMask.place(glyphs, in: fill, scale: scale)
        }
    }

    private func inkModeDidChange() {
        drawn = nil
        fill.isHidden = !wantsUpdateLayer
        // The stock drawing's backing store, from before; the glyphs replace it.
        if wantsUpdateLayer { layer?.contents = nil } else { for view in stockTextViews { view.alphaValue = 1 } }
        needsDisplay = true
    }

    /// AppKit draws a label's text in a subview of its own (`NSTextFieldSimpleLabel` on macOS 26
    /// and later), in the stock color and over nothing that blends: the glyphs replace it, so it
    /// draws transparent (else the text draws twice, 12% heavier, and its color snaps under the
    /// blend). Its alpha, not `isHidden`: AppKit shows and hides that view itself on layout. The
    /// field editor of a selected or edited label is not one of them.
    private var stockTextViews: [NSView] { subviews.filter { !($0 is NSClipView || $0 is NSText) } }

    private func hideStockText() {
        guard wantsUpdateLayer else { return }
        for view in stockTextViews where view.alphaValue != 0 { view.alphaValue = 0 }
    }

    override open func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        hideStockText()
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

    /// The field's text without its run colors: the glyphs draw in one ink.
    private func inkText() -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: attributedStringValue)
        text.removeAttribute(.foregroundColor, range: NSRange(location: 0, length: text.length))
        return text
    }

    /// The glyph coverage, upright: a copy of the field's cell drawn without a background, in the
    /// text color's stem weight, at the backing scale.
    private func glyphImage(_ ink: Ink, color: CGColor?) -> CGImage? {
        guard ink.text.length > 0, let cell = cell?.copy() as? NSTextFieldCell else { return nil }
        return GlyphMask.image(size: ink.size, scale: ink.scale, ink: color) { _, opaque in
            let text = NSMutableAttributedString(attributedString: ink.text)
            text.addAttribute(.foregroundColor, value: NSColor(cgColor: opaque) ?? .black, range: NSRange(location: 0, length: text.length))
            cell.drawsBackground = false
            cell.attributedStringValue = text
            cell.draw(withFrame: NSRect(origin: .zero, size: ink.size), in: self)
        }
    }

    /// What the glyphs show (not their color; only the color's stem weight).
    private struct Ink: Equatable {
        var text: NSAttributedString
        var size: CGSize
        var scale: CGFloat
        var weight: Int
        var lines: Int
        var lineBreak: NSLineBreakMode
        var alignment: NSTextAlignment
        var truncates: Bool
        var wraps: Bool
    }
}

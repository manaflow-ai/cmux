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
        let scale = window?.backingScaleFactor ?? layer.contentsScale
        if fill.frame != layer.bounds || glyphs.contentsScale != scale {
            fill.frame = layer.bounds
            glyphs.contentsScale = scale
        }
        let ink = Ink(text: inkText(), size: bounds.size, scale: scale, lines: maximumNumberOfLines,
                      lineBreak: lineBreakMode, alignment: alignment,
                      truncates: cell?.truncatesLastVisibleLine ?? false, wraps: cell?.wraps ?? false)
        if ink != drawn {
            drawn = ink
            let image = glyphImage(ink)
            glyphs.contents = image
            // The image at its own pixel size (whole pixels, rounded up), top edge on the field's
            // top edge, as the field's backing store sits: no resampling.
            let size = image.map { CGSize(width: CGFloat($0.width) / scale, height: CGFloat($0.height) / scale) } ?? .zero
            let top = ScrollEdgeFade.rendersTopDown(fill) ? 0 : fill.bounds.height - size.height
            glyphs.frame = CGRect(origin: CGPoint(x: 0, y: top), size: size)
        }
    }

    private func inkModeDidChange() {
        drawn = nil
        // The stock drawing's backing store, from before; the glyphs replace it.
        if wantsUpdateLayer { layer?.contents = nil }
        needsDisplay = true
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

    /// The glyph coverage, upright: a copy of the field's cell drawn in black without a
    /// background, at the backing scale.
    private func glyphImage(_ ink: Ink) -> CGImage? {
        let width = Int((ink.size.width * ink.scale).rounded(.up)), height = Int((ink.size.height * ink.scale).rounded(.up))
        guard ink.text.length > 0, width > 0, height > 0, let cell = cell?.copy() as? NSTextFieldCell,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cell.drawsBackground = false
        cell.textColor = .black
        cell.attributedStringValue = ink.text
        // The field draws in flipped coordinates, top row first.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: ink.scale, y: -ink.scale)
        // What AppKit enables for label text (a transparent layer leaves it off).
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        cell.draw(withFrame: NSRect(origin: .zero, size: ink.size), in: self)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
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

public import AppKit
public import QuartzCore

/// Single-line chrome text on a layer, drawn the way AppKit draws labels.
///
/// `CATextLayer` renders without font smoothing on a transparent layer, so
/// its glyphs come out visibly thinner than an `NSTextField` next to them.
/// This layer draws the string with Core Text through ``GlyphMask``, the
/// drawing ``ChromeLabel`` uses too, so both match an AppKit label's weight
/// in any theme. Set `contentsScale` to the window's backing scale, like any
/// drawn layer.
///
/// The color is a layer property, not drawn ink (I5, cx-8w027.3): the glyphs
/// draw once as the mask of a fill layer whose `backgroundColor` is
/// ``foregroundColor``, so a theme change blends the text on the render server
/// from the color on screen (`ThemeRepaint`). A color change that moves the
/// ink to another stem weight (``GlyphMask/weight(of:)``) shows that weight's
/// glyphs at once (drawn once per weight for the same line), so the blend ends
/// at the weight AppKit draws the new color with.
///
/// The text is top-aligned like `CATextLayer`: the first baseline sits
/// `font.ascender` below the top edge. Overflow is clipped, not truncated;
/// callers fade it with a mask (on this layer: the fill and its glyph mask are
/// sublayers).
nonisolated public final class ChromeTextLayer: CALayer {
    public var string: String = "" {
        didSet { if oldValue != string { invalidate() } }
    }

    public var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize) {
        didSet { if oldValue != font { invalidate() } }
    }

    public var foregroundColor: CGColor? = ThemeSnapshot.tokens.textPrimary.cgColor {
        didSet { if oldValue != foregroundColor { applyColor() } }
    }

    /// Where a string wider than the layer gets its ellipsis (an AppKit label's
    /// `.byTruncatingTail`, `.byTruncatingMiddle`, `.byTruncatingHead`); nil clips it.
    public var truncation: CTLineTruncationType? {
        didSet { if oldValue != truncation { redraw() } }
    }

    /// `.left`, `.center` or `.right`; anything else draws left-aligned.
    public var alignmentMode: NSTextAlignment = .left {
        didSet { if oldValue != alignmentMode { redraw() } }
    }

    override public var contentsScale: CGFloat {
        didSet {
            guard oldValue != contentsScale else { return }
            layoutFill()
            redraw()
        }
    }

    override public var bounds: CGRect {
        didSet {
            guard oldValue.size != bounds.size else { return }
            layoutFill()
            // Truncation and alignment follow the width, which the whole-pixel mask may not show.
            redraw()
        }
    }

    /// The text color, masked by ``glyphs``.
    private let fill = CALayer()
    private let glyphs = GlyphLayer()
    private var cachedLine: CTLine?
    /// The stem weight of the ink ``glyphs`` shows.
    private var drawnWeight: Int?
    /// The line's glyph image per stem weight: a color change between two weights (a tab's selected
    /// and plain colors) swaps images and draws each weight once.
    private var images: [Int: CGImage] = [:]

    override public init() {
        super.init()
        let still: [String: any CAAction] = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(),
                                             "contents": NSNull(), "frame": NSNull()]
        fill.actions = still
        glyphs.actions = still
        glyphs.owner = self
        glyphs.needsDisplayOnBoundsChange = true
        fill.mask = glyphs
        addSublayer(fill)
        applyColor()
    }

    override public init(layer: Any) {
        if let other = layer as? ChromeTextLayer {
            string = other.string
            font = other.font
            foregroundColor = other.foregroundColor
            alignmentMode = other.alignmentMode
            truncation = other.truncation
        }
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Typographic width of `string` in points.
    public var textWidth: CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(), nil, nil, nil))
    }

    /// Redraws the glyphs (the color needs no redraw).
    override public func setNeedsDisplay() {
        redraw()
    }

    private func redraw() {
        images = [:]
        glyphs.setNeedsDisplay()
    }

    override public func layoutSublayers() {
        super.layoutSublayers()
        layoutFill()
    }

    private func layoutFill() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = CGRect(origin: .zero, size: bounds.size)
        GlyphMask.place(glyphs, in: fill, scale: contentsScale)
        CATransaction.commit()
    }

    private func applyColor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.backgroundColor = foregroundColor
        CATransaction.commit()
        let weight = GlyphMask.weight(of: foregroundColor)
        guard let drawnWeight, drawnWeight != weight else { return }
        if let image = images[weight] {
            self.drawnWeight = weight
            glyphs.contents = image
        } else {
            glyphs.setNeedsDisplay()
        }
    }

    private func invalidate() {
        cachedLine = nil
        redraw()
    }

    private func line() -> CTLine {
        if let cachedLine { return cachedLine }
        // Color is applied at draw time from the context, so a color change
        // does not rebuild the line.
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        // The UI font's tracking at this size (`BundledFonts.kern`); other faces keep their own
        // kerning (an explicit 0 would turn it off).
        let kern = BundledFonts.kern(for: font)
        if kern != 0 { attributes[.kern] = kern }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        cachedLine = line
        return line
    }

    /// The glyph coverage, opaque where the text is: the mask of ``fill``.
    fileprivate func glyphImage() -> CGImage? {
        let weight = GlyphMask.weight(of: foregroundColor)
        drawnWeight = weight
        if let image = images[weight] { return image }
        let image = drawLine()
        images[weight] = image
        return image
    }

    private func drawLine() -> CGImage? {
        guard !string.isEmpty else { return nil }
        let size = bounds.size
        var line = line()
        if let truncation, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > size.width {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: [
                .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]))
            line = CTLineCreateTruncatedLine(line, Double(size.width), truncation, ellipsis) ?? line
        }
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let x: CGFloat = switch alignmentMode {
        case .center: (size.width - width) / 2
        case .right: size.width - width
        default: 0
        }
        let scale = max(contentsScale, 1)
        let font = font
        return GlyphMask.image(size: size, scale: scale, ink: foregroundColor) { ctx, _ in
            // Top-down space: the baseline sits `ascender` below the top edge, on a whole pixel.
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(x: (x * scale).rounded() / scale, y: (font.ascender * scale).rounded() / scale)
            CTLineDraw(line, ctx)
        }
    }
}

/// ``ChromeTextLayer``'s glyphs: the ``GlyphMask`` image of its line.
nonisolated private final class GlyphLayer: CALayer {
    weak var owner: ChromeTextLayer?

    override func display() {
        contents = owner?.glyphImage()
    }
}

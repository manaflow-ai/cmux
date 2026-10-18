public import AppKit
public import QuartzCore

/// Single-line chrome text on a layer, drawn the way AppKit draws labels.
///
/// `CATextLayer` renders without font smoothing on a transparent layer, so
/// its glyphs come out visibly thinner than an `NSTextField` next to them.
/// This layer draws the string with Core Text with font smoothing enabled,
/// which matches AppKit label weight. Set `contentsScale` to the window's
/// backing scale, like any drawn layer.
///
/// The color is a layer property, not drawn ink (I5, cx-8w027.3): the glyphs
/// draw once as the mask of a fill layer whose `backgroundColor` is
/// ``foregroundColor``, so a theme change blends the text on the render server
/// from the color on screen (`ThemeRepaint`) and a color change redraws no
/// glyphs.
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
        didSet { if oldValue != truncation { glyphs.setNeedsDisplay() } }
    }

    /// `.left`, `.center` or `.right`; anything else draws left-aligned.
    public var alignmentMode: NSTextAlignment = .left {
        didSet { if oldValue != alignmentMode { glyphs.setNeedsDisplay() } }
    }

    override public var contentsScale: CGFloat {
        didSet { glyphs.contentsScale = contentsScale }
    }

    override public var bounds: CGRect {
        didSet { if oldValue.size != bounds.size { layoutFill() } }
    }

    /// The text color, masked by ``glyphs``.
    private let fill = CALayer()
    private let glyphs = GlyphLayer()
    private var cachedLine: CTLine?

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
        glyphs.frame = fill.bounds
        CATransaction.commit()
    }

    private func applyColor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.backgroundColor = foregroundColor
        CATransaction.commit()
    }

    private func invalidate() {
        cachedLine = nil
        glyphs.setNeedsDisplay()
    }

    private func line() -> CTLine {
        if let cachedLine { return cachedLine }
        // Color is applied at draw time from the context, so a color change
        // does not rebuild the line.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        cachedLine = line
        return line
    }

    /// The glyph coverage, opaque where the text is: the mask of ``fill``.
    fileprivate func drawGlyphs(in ctx: CGContext, bounds: CGRect, flipped: Bool, scale: CGFloat) {
        guard !string.isEmpty else { return }
        var line = line()
        if let truncation, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > bounds.width {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: [
                .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]))
            line = CTLineCreateTruncatedLine(line, Double(bounds.width), truncation, ellipsis) ?? line
        }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // What AppKit enables for label text; CATextLayer leaves it off on
        // non-opaque layers, which is why its text reads thin.
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let x: CGFloat = switch alignmentMode {
        case .center: (bounds.width - width) / 2
        case .right: bounds.width - width
        default: 0
        }
        // Layer contexts on macOS are unflipped unless the geometry is.
        let raw = flipped ? font.ascender : bounds.height - font.ascender
        let scale = max(scale, 1)
        let baseline = (raw * scale).rounded() / scale
        ctx.textMatrix = flipped ? CGAffineTransform(scaleX: 1, y: -1) : .identity
        ctx.textPosition = CGPoint(x: (x * scale).rounded() / scale, y: baseline)
        CTLineDraw(line, ctx)
    }
}

/// ``ChromeTextLayer``'s glyphs, drawn in its own context's orientation.
nonisolated private final class GlyphLayer: CALayer {
    weak var owner: ChromeTextLayer?

    override func draw(in ctx: CGContext) {
        owner?.drawGlyphs(in: ctx, bounds: bounds, flipped: contentsAreFlipped(), scale: contentsScale)
    }
}

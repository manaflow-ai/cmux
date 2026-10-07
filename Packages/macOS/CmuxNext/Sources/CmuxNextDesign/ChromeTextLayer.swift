public import AppKit
public import QuartzCore

/// Single-line chrome text on a layer, drawn the way AppKit draws labels.
///
/// `CATextLayer` renders without font smoothing on a transparent layer, so
/// its glyphs come out visibly thinner than an `NSTextField` next to them.
/// This layer draws the string with Core Text into its own backing store
/// with font smoothing enabled, which matches AppKit label weight. Set
/// `contentsScale` to the window's backing scale, like any drawn layer.
///
/// The text is top-aligned like `CATextLayer`: the first baseline sits
/// `font.ascender` below the top edge. Overflow is clipped, not truncated;
/// callers fade it with a mask.
nonisolated public final class ChromeTextLayer: CALayer {
    public var string: String = "" {
        didSet { if oldValue != string { invalidate() } }
    }

    public var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize) {
        didSet { if oldValue != font { invalidate() } }
    }

    public var foregroundColor: CGColor? = ThemeSnapshot.tokens.textPrimary.cgColor {
        didSet { if oldValue != foregroundColor { setNeedsDisplay() } }
    }

    /// `.left`, `.center` or `.right`; anything else draws left-aligned.
    public var alignmentMode: NSTextAlignment = .left {
        didSet { if oldValue != alignmentMode { setNeedsDisplay() } }
    }

    private var cachedLine: CTLine?

    override public init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override public init(layer: Any) {
        if let other = layer as? ChromeTextLayer {
            string = other.string
            font = other.font
            foregroundColor = other.foregroundColor
            alignmentMode = other.alignmentMode
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

    private func invalidate() {
        cachedLine = nil
        setNeedsDisplay()
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

    override public func draw(in ctx: CGContext) {
        guard !string.isEmpty, let foregroundColor else { return }
        let line = line()
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // What AppKit enables for label text; CATextLayer leaves it off on
        // non-opaque layers, which is why its text reads thin.
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setFillColor(foregroundColor)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let x: CGFloat = switch alignmentMode {
        case .center: (bounds.width - width) / 2
        case .right: bounds.width - width
        default: 0
        }
        // Layer contexts on macOS are unflipped unless the geometry is.
        let flipped = contentsAreFlipped()
        let raw = flipped ? font.ascender : bounds.height - font.ascender
        let scale = max(contentsScale, 1)
        let baseline = (raw * scale).rounded() / scale
        ctx.textMatrix = flipped ? CGAffineTransform(scaleX: 1, y: -1) : .identity
        ctx.textPosition = CGPoint(x: (x * scale).rounded() / scale, y: baseline)
        CTLineDraw(line, ctx)
    }
}

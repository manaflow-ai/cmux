public import AppKit
public import CmuxNextDesignTokens
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
            if keepsGlyphs(from: oldValue.size) {
                layoutFill()
                return
            }
            keptWidth = nil
            layoutFill()
            // Truncation and alignment follow the width, which the whole-pixel mask may not show.
            redraw()
        }
    }

    /// The text color, masked by ``glyphs``.
    private let fill = CALayer()
    private let glyphs = GlyphLayer()
    private var cachedLine: CTLine?
    private var cachedWordStarts: [TitleFadeGeometry.WordStart]?
    /// The stem weight of the ink ``glyphs`` shows.
    private var drawnWeight: Int?
    /// The line's glyph image per stem weight: a color change between two weights (a tab's selected
    /// and plain colors) swaps images and draws each weight once.
    private var images: [Int: CGImage] = [:]
    /// The width ``images`` were drawn at, while a width change that moves no glyph keeps them
    /// (``keepsGlyphs(from:)``); nil while the glyphs span the layer.
    private var keptWidth: CGFloat?
    /// Lines drawn, for tests.
    private(set) var glyphDraws = 0

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

    /// Where each word after a space starts on the line, and where its first glyph ends (its next composed
    /// character's offset): what a trailing fade must not cut (``TitleFadeGeometry/fadeEnd``). Measured once per
    /// string and font.
    public var wordStarts: [TitleFadeGeometry.WordStart] {
        if let cachedWordStarts { return cachedWordStarts }
        let starts = Self.wordStarts(in: string as NSString, line: line())
        cachedWordStarts = starts
        return starts
    }

    static func wordStarts(in text: NSString, line: CTLine) -> [TitleFadeGeometry.WordStart] {
        let spaces = CharacterSet.whitespacesAndNewlines
        func isSpace(_ index: Int) -> Bool { UnicodeScalar(text.character(at: index)).map(spaces.contains) ?? false }
        var starts: [TitleFadeGeometry.WordStart] = []
        var index = 1
        while index < text.length {
            let glyph = text.rangeOfComposedCharacterSequence(at: index)
            defer { index = glyph.upperBound }
            guard isSpace(index - 1), !isSpace(index) else { continue }
            let x = CTLineGetOffsetForStringIndex(line, index, nil)
            let end = CTLineGetOffsetForStringIndex(line, glyph.upperBound, nil)
            if end > x { starts.append(.init(x: x, firstGlyphEnd: end)) }
        }
        return starts
    }

    /// Redraws the glyphs (the color needs no redraw).
    override public func setNeedsDisplay() {
        redraw()
    }

    private func redraw() {
        images = [:]
        if keptWidth != nil {
            keptWidth = nil
            layoutFill()
        }
        glyphs.setNeedsDisplay()
    }

    /// A width change of a left-aligned line that fits both the drawn width and the new one draws the
    /// same pixels at either: no ellipsis, nothing clipped, the first glyph at x 0. So its glyphs stay,
    /// on a mask at the width they were drawn at; the fill shows nothing past the line. A sidebar
    /// title narrowing for a status glyph and widening again then draws nothing.
    private func keepsGlyphs(from old: CGSize) -> Bool {
        guard old.height == bounds.height, old.width > 0, alignmentMode != .center, alignmentMode != .right,
              !images.isEmpty, !string.isEmpty else { return false }
        let drawn = keptWidth ?? old.width
        let ink = inkWidth()
        guard ink <= drawn, ink <= bounds.width else { return false }
        keptWidth = drawn
        return true
    }

    /// How far right the line's ink reaches from x 0: its advance or its glyphs' outlines, whichever
    /// is wider, and a point for smoothing, which spreads past the outline.
    private func inkWidth() -> CGFloat {
        let line = line()
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        return max(advance, CTLineGetImageBounds(line, nil).maxX) + 1
    }

    override public func layoutSublayers() {
        super.layoutSublayers()
        layoutFill()
    }

    private func layoutFill() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = CGRect(origin: .zero, size: bounds.size)
        GlyphMask.place(glyphs, in: fill, scale: contentsScale, width: keptWidth)
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

    /// ``ProcessFontSmoothing/chrome`` changed: the glyphs show the new smoothing's image, kept or
    /// drawn (``ChromeTextRefresh``). Its stem weight names the smoothing, so this is a color check.
    func smoothingDidChange() {
        applyColor()
    }

    private func invalidate() {
        cachedLine = nil
        cachedWordStarts = nil
        redraw()
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
        // Kept glyphs (``keptWidth``) draw a new ink at the width their mask still has.
        let size = CGSize(width: keptWidth ?? bounds.width, height: bounds.height)
        glyphDraws &+= 1
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

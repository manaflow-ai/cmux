public import AppKit

/// The chrome label: static text whose color blends on a theme change (I5, cx-8w027.3,
/// cx-8w027.12, cx-8w027.26).
///
/// It is its own view, not an `NSTextField`, so it depends on no AppKit internals. It has the
/// label API of an `NSTextField` (text, font, color, alignment, line break, line count,
/// preferred width, selection), with the defaults of `NSTextField(labelWithString:)` and
/// `NSTextField(wrappingLabelWithString:)`. ``LabelText`` lays the text out with TextKit the way a
/// label cell does (2 pt line fragment padding, top-aligned), and that one layout gives the
/// intrinsic size, the baselines, the wrapping, the line count and the truncation.
///
/// The glyphs draw once through ``GlyphMask`` (the drawing ``ChromeTextLayer`` uses too), as the
/// mask of a fill layer whose `backgroundColor` is ``textColor``: the color is a layer color the
/// render server blends from the color on screen (`ThemeRepaint`). The glyphs draw again only
/// when what they show changes (text, font, size, scale, line settings) or a color change moves
/// the ink to a stem weight (``GlyphMask/weight(of:)``) they were not drawn in yet; each weight's
/// image is kept for the same text. `draw(_:)` draws the same layout for `cacheDisplay` images.
///
/// One text color per label: per-run colors of an attributed string draw in ``textColor``.
/// A selectable label keeps select and copy: a mouse down puts a text view with the same layout
/// over the glyphs until it resigns first responder. It is never editable: use a text field.
open class ChromeLabel: NSView {
    // MARK: Text

    /// The text, without the label's font and color (see ``attributedStringValue``).
    private var content = NSAttributedString()

    open var stringValue: String {
        get { content.string }
        set {
            guard newValue != content.string || hasRunAttributes else { return }
            content = NSAttributedString(string: newValue)
            hasRunAttributes = false
            textDidChange()
        }
    }

    /// The text with its own runs; a run without a font draws in ``font``.
    open var attributedStringValue: NSAttributedString {
        get { LabelText.styled(content, font: font, color: textColor) }
        set {
            content = newValue.copy() as? NSAttributedString ?? newValue
            hasRunAttributes = true
            textDidChange()
        }
    }

    private var hasRunAttributes = false

    open var font: NSFont? { didSet { if font != oldValue { textDidChange() } } }
    open var textColor: NSColor? { didSet { if textColor != oldValue { needsDisplay = true } } }
    open var alignment: NSTextAlignment = .natural { didSet { if alignment != oldValue { textDidChange() } } }

    /// As `NSCell`: a wrapping mode turns ``wraps`` on, any other mode turns it off.
    open var lineBreakMode: NSLineBreakMode = .byClipping {
        didSet {
            wraps = lineBreakMode == .byWordWrapping || lineBreakMode == .byCharWrapping
            if lineBreakMode != oldValue { textDidChange() }
        }
    }

    /// Lines wrap at the width (with ``maximumNumberOfLines`` 0). A label with more than one
    /// line allowed wraps too, and ``lineBreakMode`` applies to its last line.
    open var wraps = false { didSet { if wraps != oldValue { textDidChange() } } }

    /// 0: no limit (wrapping labels); 1: one line.
    open var maximumNumberOfLines = 1 { didSet { if maximumNumberOfLines != oldValue { textDidChange() } } }

    /// The last line that fits the height truncates (with a truncating ``lineBreakMode``).
    open var truncatesLastVisibleLine = false { didSet { if truncatesLastVisibleLine != oldValue { textDidChange() } } }
    open var allowsDefaultTighteningForTruncation = false {
        didSet { if allowsDefaultTighteningForTruncation != oldValue { textDidChange() } }
    }

    /// The width a wrapping label measures its height at; 0: its current width.
    open var preferredMaxLayoutWidth: CGFloat = 0 { didSet { if preferredMaxLayoutWidth != oldValue { textDidChange() } } }

    open var drawsBackground = false { didSet { needsDisplay = true } }
    open var backgroundColor: NSColor? { didSet { needsDisplay = true } }

    /// Select and copy (a mouse down starts a selection).
    open var isSelectable = false {
        didSet {
            if !isSelectable { endSelection() }
            window?.invalidateCursorRects(for: self)
        }
    }

    // MARK: Init

    public convenience init(labelWithString string: String) {
        self.init(frame: .zero)
        apply(LabelDefaults.label)
        stringValue = string
        frame.size = intrinsicSize(width: nil)
    }

    public convenience init(wrappingLabelWithString string: String) {
        self.init(frame: .zero)
        apply(LabelDefaults.wrapping)
        stringValue = string
        frame.size = intrinsicSize(width: nil)
    }

    public convenience init(font: NSFont) {
        self.init(labelWithString: "")
        self.font = font
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        truncatesLastVisibleLine = true
    }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        apply(LabelDefaults.label)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        apply(LabelDefaults.label)
    }

    private func apply(_ defaults: LabelDefaults) {
        font = defaults.font
        textColor = defaults.textColor
        alignment = defaults.alignment
        lineBreakMode = defaults.lineBreakMode
        wraps = defaults.wraps
        maximumNumberOfLines = defaults.maximumNumberOfLines
        truncatesLastVisibleLine = defaults.truncatesLastVisibleLine
        allowsDefaultTighteningForTruncation = defaults.allowsDefaultTightening
        isSelectable = defaults.isSelectable
    }

    // MARK: Layout

    override open var isFlipped: Bool { true }

    /// The text's shape settings (not its color).
    var shape: LabelText.Shape {
        LabelText.Shape(lines: maximumNumberOfLines, wraps: wraps, lineBreak: lineBreakMode, alignment: alignment,
                        tightens: allowsDefaultTighteningForTruncation, truncatesLastVisibleLine: truncatesLastVisibleLine)
    }

    /// The text with the label's font, in `color` (all runs).
    func inkText(color: NSColor?) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: LabelText.styled(content, font: font, color: nil))
        let all = NSRange(location: 0, length: text.length)
        if let color { text.addAttribute(.foregroundColor, value: color, range: all) } else { text.removeAttribute(.foregroundColor, range: all) }
        return text
    }

    /// Measured layouts by width (nil: unbounded); dropped on any text change.
    private var measured: [CGFloat: LabelText.Metrics] = [:]

    func metrics(width: CGFloat?) -> LabelText.Metrics {
        let key = width ?? -1
        if let known = measured[key] { return known }
        let value = LabelText.measure(inkText(color: nil), font: font, shape: shape, width: width)
        if measured.count >= 8 { measured.removeAll() }
        measured[key] = value
        return value
    }

    /// The width a wrapping label lays out at for its intrinsic size; nil: one line, unbounded.
    private var measureWidth: CGFloat? {
        guard shape.isMultiline else { return nil }
        if preferredMaxLayoutWidth > 0 { return preferredMaxLayoutWidth }
        return bounds.width > 0 ? bounds.width : nil
    }

    private func intrinsicSize(width: CGFloat?) -> NSSize { metrics(width: width).size }

    override open var intrinsicContentSize: NSSize {
        let size = intrinsicSize(width: measureWidth)
        // A wrapping label without a preferred width takes the width its layout gives it.
        if shape.isMultiline, preferredMaxLayoutWidth <= 0 { return NSSize(width: NSView.noIntrinsicMetric, height: size.height) }
        return size
    }

    override open var firstBaselineOffsetFromTop: CGFloat { metrics(width: measureWidth).firstBaseline }
    override open var lastBaselineOffsetFromBottom: CGFloat { metrics(width: measureWidth).lastBaselineFromBottom }

    /// The intrinsic size; a wrapping label keeps its width (or its preferred width).
    open func sizeToFit() {
        setFrameSize(intrinsicSize(width: measureWidth))
    }

    /// The text's own size, as a label cell's `cellSize`: one line unbounded, a wrapping label at
    /// its preferred (or current) width. Unlike ``intrinsicContentSize`` it always has a width.
    public var naturalSize: NSSize { intrinsicSize(width: measureWidth) }

    /// The size of the text laid out at `width` (a wrapping label's height at that width).
    public func size(forWidth width: CGFloat) -> NSSize { intrinsicSize(width: width) }

    override open func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width, changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed else { return }
        if widthChanged, shape.isMultiline, preferredMaxLayoutWidth <= 0 { invalidateIntrinsicContentSize() }
        endSelection()
        needsDisplay = true
    }

    private func textDidChange() {
        measured.removeAll()
        endSelection()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    // MARK: Drawing

    /// The text color, masked by ``glyphs``.
    private let fill = CALayer()
    private let glyphs = CALayer()
    /// What ``glyphs`` shows now and in which stem weight; a different one draws them again.
    private var drawn: (ink: Ink, weight: Int)?
    /// The glyph image of `drawn.ink` per stem weight: a color change between two weights (a
    /// selected row's color and its plain one) swaps images and draws each weight once.
    private var images: [Int: CGImage] = [:]

    override open var wantsUpdateLayer: Bool { true }

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
        // AppKit runs this with the view's appearance as the drawing appearance: dynamic colors
        // resolve as they do in `draw(_:)`.
        layer.backgroundColor = drawsBackground ? backgroundColor?.cgColor : nil
        fill.backgroundColor = textColor?.cgColor
        fill.isHidden = selection != nil
        let scale = window?.backingScaleFactor ?? layer.contentsScale
        if fill.frame != layer.bounds { fill.frame = layer.bounds }
        let color = textColor?.cgColor, weight = GlyphMask.weight(of: color)
        let ink = Ink(text: inkText(color: nil), shape: shape, size: bounds.size, scale: scale)
        guard drawn?.ink != ink || drawn?.weight != weight else { return }
        if drawn?.ink != ink { images = [:] }
        drawn = (ink, weight)
        let image = images[weight] ?? glyphImage(ink, color: color)
        images[weight] = image
        glyphs.contents = image
        // The image at its own pixel size, top edge on top.
        GlyphMask.place(glyphs, in: fill, scale: scale)
    }

    /// The same text for an image of the view (`cacheDisplay`, drag images): AppKit draws a
    /// layer-updating view this way outside its layer.
    override open func draw(_ dirtyRect: NSRect) {
        if drawsBackground, let backgroundColor {
            backgroundColor.setFill()
            bounds.fill()
        }
        guard selection == nil, let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Font smoothing (stem darkening) as AppKit draws a label: an image context leaves it off.
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)
        LabelText.draw(inkText(color: textColor ?? .labelColor), shape: shape, in: bounds.size)
    }

    override open func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    /// The glyph coverage, upright, in the text color's stem weight, at the backing scale.
    private func glyphImage(_ ink: Ink, color: CGColor?) -> CGImage? {
        guard ink.text.length > 0 else { return nil }
        return GlyphMask.image(size: ink.size, scale: ink.scale, ink: color) { _, opaque in
            let text = NSMutableAttributedString(attributedString: ink.text)
            text.addAttribute(.foregroundColor, value: NSColor(cgColor: opaque) ?? .black, range: NSRange(location: 0, length: text.length))
            LabelText.draw(text, shape: ink.shape, in: ink.size)
        }
    }

    /// What the glyphs show (not their color).
    private struct Ink: Equatable {
        var text: NSAttributedString
        var shape: LabelText.Shape
        var size: CGSize
        var scale: CGFloat
    }

    // MARK: Selection

    /// The text view of a live selection; nil when nothing is selected.
    private(set) var selection: LabelSelectionView?

    override open func mouseDown(with event: NSEvent) {
        guard isSelectable, let window else { return super.mouseDown(with: event) }
        let view = selection ?? beginSelection(in: window)
        view.mouseDown(with: event)
    }

    override open var mouseDownCanMoveWindow: Bool { !isSelectable }

    override open func resetCursorRects() {
        if isSelectable { addCursorRect(bounds, cursor: .iBeam) }
    }

    private func beginSelection(in window: NSWindow) -> LabelSelectionView {
        let view = LabelSelectionView(text: inkText(color: textColor ?? .labelColor), shape: shape, size: bounds.size)
        view.frame = bounds
        view.didResign = { [weak self] in self?.endSelection(resigned: true) }
        addSubview(view)
        selection = view
        needsDisplay = true
        window.makeFirstResponder(view)
        return view
    }

    /// `resigned`: the view is giving up first responder now (do not move it again).
    private func endSelection(resigned: Bool = false) {
        guard let view = selection else { return }
        selection = nil
        view.didResign = nil
        if !resigned, window?.firstResponder === view { window?.makeFirstResponder(nil) }
        view.removeFromSuperview()
        needsDisplay = true
    }

    // MARK: Accessibility (a static text element, as a label field)

    override open func isAccessibilityElement() -> Bool { true }
    override open func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override open func accessibilityValue() -> Any? { stringValue }
    override open func accessibilityNumberOfCharacters() -> Int { content.length }
    override open func accessibilityVisibleCharacterRange() -> NSRange { NSRange(location: 0, length: content.length) }

    override open func accessibilityString(for range: NSRange) -> String? {
        guard range.location >= 0, NSMaxRange(range) <= content.length else { return nil }
        return (content.string as NSString).substring(with: range)
    }

    override open func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard range.location >= 0, NSMaxRange(range) <= content.length else { return nil }
        return attributedStringValue.attributedSubstring(from: range)
    }
}

/// A view that shows a line of text: a stock `NSTextField` or a ``ChromeLabel``.
public protocol ShownText: NSView {
    var stringValue: String { get set }
    var textColor: NSColor? { get set }
    var font: NSFont? { get set }
}

extension NSTextField: ShownText {}
extension ChromeLabel: ShownText {}

/// The label defaults of AppKit's label factories, read once.
private struct LabelDefaults {
    var font: NSFont?
    var textColor: NSColor?
    var alignment: NSTextAlignment
    var lineBreakMode: NSLineBreakMode
    var wraps: Bool
    var maximumNumberOfLines: Int
    var truncatesLastVisibleLine: Bool
    var allowsDefaultTightening: Bool
    var isSelectable: Bool

    static let label = LabelDefaults(NSTextField(labelWithString: ""))
    static let wrapping = LabelDefaults(NSTextField(wrappingLabelWithString: ""))

    init(_ field: NSTextField) {
        font = field.font
        textColor = field.textColor
        alignment = field.alignment
        lineBreakMode = field.lineBreakMode
        wraps = field.cell?.wraps ?? false
        maximumNumberOfLines = field.maximumNumberOfLines
        truncatesLastVisibleLine = field.cell?.truncatesLastVisibleLine ?? false
        allowsDefaultTightening = field.allowsDefaultTighteningForTruncation
        isSelectable = field.isSelectable
    }
}

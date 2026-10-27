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
/// the ink to a stem weight (``GlyphMask/weight(of:)``) they were not drawn in yet; the images are
/// kept in the scope's ``GlyphMaskCache`` (equal labels draw once), else per weight for the same
/// text. `draw(_:)` draws the same layout for `cacheDisplay` images.
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
            guard !hasRunAttributes || !newValue.isEqual(to: content) else { return } // the same runs: nothing to measure
            content = newValue.copy() as? NSAttributedString ?? newValue
            hasRunAttributes = true
            textDidChange()
        }
    }

    private var hasRunAttributes = false

    open var font: NSFont? { didSet { if font != oldValue { textDidChange() } } }
    open var textColor: NSColor? { didSet { if textColor != oldValue { needsDisplay = true } } }
    open var alignment: NSTextAlignment = .natural { didSet { if alignment != oldValue { textDidChange() } } }

    /// As `NSCell`'s: a wrapping mode turns ``wraps`` on, any other mode turns it off.
    open var lineBreakMode: NSLineBreakMode = .byClipping {
        didSet {
            let wrapping = Self.isWrapping(lineBreakMode)
            if wraps != wrapping { wraps = wrapping }
            if lineBreakMode != oldValue { textDidChange() }
        }
    }

    /// Lines break at the width, up to ``maximumNumberOfLines`` (0: no limit). As `NSCell`'s:
    /// turning it on sets ``lineBreakMode`` to word wrapping, turning it off to clipping.
    open var wraps = false {
        didSet {
            guard wraps != oldValue else { return }
            if Self.isWrapping(lineBreakMode) != wraps { lineBreakMode = wraps ? .byWordWrapping : .byClipping }
            textDidChange()
        }
    }

    private static func isWrapping(_ mode: NSLineBreakMode) -> Bool { mode == .byWordWrapping || mode == .byCharWrapping }

    /// 0: no limit (wrapping labels); 1: one line.
    open var maximumNumberOfLines = 1 { didSet { if maximumNumberOfLines != oldValue { textDidChange() } } }

    /// The last line that fits the height truncates (with a truncating ``lineBreakMode``).
    open var truncatesLastVisibleLine = false { didSet { if truncatesLastVisibleLine != oldValue { textDidChange() } } }
    open var allowsDefaultTighteningForTruncation = false {
        didSet { if allowsDefaultTighteningForTruncation != oldValue { textDidChange() } }
    }

    /// How lines break at the width (a wrapping label's factory default keeps a lone word off
    /// the last line).
    open var lineBreakStrategy: NSParagraphStyle.LineBreakStrategy = [] {
        didSet { if lineBreakStrategy != oldValue { textDidChange() } }
    }

    /// The width a wrapping label measures its height at; 0: its current width.
    open var preferredMaxLayoutWidth: CGFloat = 0 { didSet { if preferredMaxLayoutWidth != oldValue { textDidChange() } } }

    open var drawsBackground = false { didSet { if drawsBackground != oldValue { needsDisplay = true } } }
    open var backgroundColor: NSColor? { didSet { if backgroundColor != oldValue { needsDisplay = true } } }

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
        frame.size = naturalSize
    }

    public convenience init(wrappingLabelWithString string: String) {
        self.init(frame: .zero)
        apply(LabelDefaults.wrapping)
        stringValue = string
        frame.size = naturalSize
    }

    public convenience init(font: NSFont) {
        self.init(labelWithString: "")
        // Through a method: an initializer's own assignments skip the property observers.
        setUp(font: font)
    }

    /// A one-line label in `font` whose text truncates at its tail.
    private func setUp(font: NSFont) {
        self.font = font
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        truncatesLastVisibleLine = true
        frame.size = naturalSize
    }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // A size change redraws through `setFrameSize`; the glyphs keep their pixel size meanwhile.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        apply(LabelDefaults.label)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
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
        lineBreakStrategy = defaults.lineBreakStrategy
        isSelectable = defaults.isSelectable
        for (orientation, hugging, resistance) in defaults.priorities {
            setContentHuggingPriority(hugging, for: orientation)
            setContentCompressionResistancePriority(resistance, for: orientation)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    // MARK: Layout

    nonisolated override open var isFlipped: Bool { true }

    /// The text's shape settings (not its color).
    var shape: LabelText.Shape {
        LabelText.Shape(lines: maximumNumberOfLines, wraps: wraps, lineBreak: lineBreakMode, alignment: alignment,
                        tightens: allowsDefaultTighteningForTruncation, truncatesLastVisibleLine: truncatesLastVisibleLine,
                        strategy: lineBreakStrategy)
    }

    /// The text with the label's font, in `color` (all runs).
    func inkText(color: NSColor?) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: LabelText.styled(content, font: font, color: nil))
        let all = NSRange(location: 0, length: text.length)
        if let color { text.addAttribute(.foregroundColor, value: color, range: all) } else { text.removeAttribute(.foregroundColor, range: all) }
        return text
    }

    /// Measured layouts by text width (nil: unbounded); dropped on any text or scale change.
    private var measured: [CGFloat: LabelText.Metrics] = [:]

    /// Pixels per point for rounding widths, as the field rounds them.
    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// The text laid out with `width` points for its lines (nil: unbounded).
    func metrics(width: CGFloat?) -> LabelText.Metrics {
        let key = width ?? -1
        if let known = measured[key] { return known }
        let value = LabelText.measure(inkText(color: nil), font: font, shape: shape, width: width, scale: scale)
        if measured.count >= 8 { measured.removeAll() }
        measured[key] = value
        return value
    }

    /// The left and right 2 pt of the frame are the text's padding, outside the alignment rect
    /// (as a label field's): the intrinsic size and the baselines are of the text itself.
    nonisolated override open var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: LabelText.padding, bottom: 0, right: LabelText.padding) }

    /// A wrapping label with more than one line breaks its lines at its preferred width, else at
    /// its current width (its intrinsic height follows the width layout gives it); nil: one line.
    private var wrapWidth: CGFloat? {
        guard maximumNumberOfLines != 1 else { return nil }
        if preferredMaxLayoutWidth > 0 { return preferredMaxLayoutWidth }
        let current = bounds.width - LabelText.padding * 2
        return shape.isMultiline && current > 0 ? current : nil
    }

    override open var intrinsicContentSize: NSSize {
        // As tall as the lines at the width they break at (the preferred width, else the
        // current one).
        let line = metrics(width: nil).size
        guard shape.isMultiline, let width = wrapWidth else {
            if maximumNumberOfLines != 1, preferredMaxLayoutWidth > 0 { return metrics(width: preferredMaxLayoutWidth).size }
            return line
        }
        let wrapped = metrics(width: width).size
        // At a preferred width: the widest wrapped line. At the current width: the one-line
        // width, so the width a layout gives the label never feeds back into it.
        return NSSize(width: preferredMaxLayoutWidth > 0 ? wrapped.width : line.width, height: wrapped.height)
    }

    override open var firstBaselineOffsetFromTop: CGFloat { metrics(width: wrapWidth).firstBaseline }
    override open var lastBaselineOffsetFromBottom: CGFloat { metrics(width: wrapWidth).lastBaselineFromBottom }

    /// The frame of the text on one line per paragraph, padding included (a field's `sizeToFit`).
    open func sizeToFit() {
        setFrameSize(naturalSize)
    }

    /// The frame the text needs on one line per paragraph, padding included: a label field cell's
    /// `cellSize`. Unlike ``intrinsicContentSize`` it is in frame terms.
    public var naturalSize: NSSize { frameSize(metrics(width: nil).size) }

    /// The frame the text needs in a frame `width` wide: a field cell's `cellSize(forBounds:)`.
    public func size(forWidth width: CGFloat) -> NSSize {
        frameSize(metrics(width: shape.isMultiline ? max(width - LabelText.padding * 2, 0) : nil).size)
    }

    private func frameSize(_ text: NSSize) -> NSSize { NSSize(width: text.width + LabelText.padding * 2, height: text.height) }

    override open func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width, changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed else { return }
        if widthChanged, shape.isMultiline, preferredMaxLayoutWidth <= 0, maximumNumberOfLines != 1 { invalidateIntrinsicContentSize() }
        endSelection()
        needsDisplay = true // invalidate: the size changed (the guard above); the lines lay out again.
    }

    private func textDidChange() {
        measured.removeAll()
        endSelection()
        invalidateIntrinsicContentSize()
        needsDisplay = true // invalidate: the text or its shape changed (the setter's check).
    }

    // MARK: Drawing

    /// The text color, masked by ``glyphs``.
    private let fill = CALayer()
    private let glyphs = CALayer()
    /// What ``glyphs`` shows now, in which stem weight; a different one draws them again.
    private var drawn: GlyphMaskCache.Key?
    /// Without a shared ``GlyphMaskCache``, the image of `drawn`'s text per stem weight: a color
    /// change between two weights (a selected row's and its plain one) draws each weight once.
    // memory: fixed one image per GlyphMask stem step (four) of this label's own text at its size;
    // a change of text, shape, size or scale empties it, and so does drawing through a shared cache.
    private var images: [Int: CGImage] = [:]

    nonisolated override open var wantsUpdateLayer: Bool { true }

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
        let key = GlyphMaskCache.Key(text: inkText(color: nil), shape: shape, size: bounds.size, scale: scale, weight: weight)
        guard drawn != key else { return }
        glyphs.contents = glyphImage(key, color: color)
        drawn = key
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
        LabelText.draw(inkText(color: textColor ?? .labelColor), shape: shape, in: bounds.size, context: ctx)
    }

    override open func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        measured.removeAll()
        invalidateIntrinsicContentSize()
        needsDisplay = true // invalidate: the scale changed; the glyphs measure and rasterize again.
    }

    /// The image of `key` (`color` in its stem weight): the scope's shared one, else this label's.
    private func glyphImage(_ key: GlyphMaskCache.Key, color: CGColor?) -> CGImage? {
        let masks = themeScope.glyphMasks
        if masks != nil || drawn?.showsSameText(as: key) != true { images = [:] }
        guard key.text.length > 0 else { return nil }
        if let masks { return masks.image(for: key) { rasterize(key, color: color) } }
        let image = images[key.weight] ?? rasterize(key, color: color)
        images[key.weight] = image
        return image
    }

    /// The glyph coverage, upright, in the text color's stem weight, at the backing scale.
    private func rasterize(_ key: GlyphMaskCache.Key, color: CGColor?) -> CGImage? {
        GlyphMask.image(size: key.size, scale: key.scale, ink: color) { ctx, opaque in
            let text = NSMutableAttributedString(attributedString: key.text)
            text.addAttribute(.foregroundColor, value: NSColor(cgColor: opaque) ?? .black, range: NSRange(location: 0, length: text.length))
            LabelText.draw(text, shape: key.shape, in: key.size, context: ctx)
        }
    }

    // MARK: Selection

    /// The text view of a live selection; nil when nothing is selected.
    private(set) var selection: LabelSelectionView?

    override open func mouseDown(with event: NSEvent) {
        guard isSelectable, let window, let view = selection ?? beginSelection(in: window) else { return super.mouseDown(with: event) }
        // A focus change in `beginSelection` can end the selection again (a resize, new text).
        guard view.superview === self else { return }
        view.mouseDown(with: event)
    }

    override open var mouseDownCanMoveWindow: Bool { !isSelectable }

    override open func resetCursorRects() {
        if isSelectable { addCursorRect(bounds, cursor: .iBeam) }
    }

    /// The selection's text view, first responder; nil when the window keeps its first responder.
    private func beginSelection(in window: NSWindow) -> LabelSelectionView? {
        let view = LabelSelectionView(text: inkText(color: textColor ?? .labelColor), shape: shape, size: bounds.size)
        view.frame = bounds
        view.didResign = { [weak self] in self?.endSelection(resigned: true) }
        addSubview(view)
        selection = view
        needsDisplay = true // invalidate: the selection view draws the text now; the label draws none.
        guard window.makeFirstResponder(view) else {
            endSelection(resigned: true)
            return nil
        }
        return view
    }

    /// `resigned`: the view is giving up first responder now (do not move it again; it leaves
    /// the label after the window's responder change, not inside it).
    private func endSelection(resigned: Bool = false) {
        guard let view = selection else { return }
        selection = nil
        view.didResign = nil
        needsDisplay = true // invalidate: the selection ended (the guard above); the label draws its text again.
        guard resigned else {
            if window?.firstResponder === view { window?.makeFirstResponder(nil) }
            view.removeFromSuperview()
            return
        }
        // Not `isHidden`: hiding the first responder moves first responder again, inside this change.
        view.alphaValue = 0
        // main-hop-allow: AppKit focus order: the view is resigning first responder inside the window's responder change, so it leaves one job after that change
        Task { @MainActor in view.removeFromSuperview() }
    }

    // MARK: Accessibility (a static text element, as a label field; `apply` sets the element
    // and its role, so `setAccessibilityElement(false)` hides it as it hides a field)

    /// As a label field's cell reports it: 1 pt in from each side, 1 pt out at top and bottom.
    override open func accessibilityFrame() -> NSRect {
        guard let window else { return super.accessibilityFrame() }
        return window.convertToScreen(convert(bounds.insetBy(dx: 1, dy: -1), to: nil))
    }
    /// The text, unless a value was set (`setAccessibilityValue`).
    override open func accessibilityValue() -> Any? { super.accessibilityValue() ?? stringValue }
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
    var lineBreakStrategy: NSParagraphStyle.LineBreakStrategy
    var isSelectable: Bool
    /// Content hugging and compression resistance per axis.
    var priorities: [(NSLayoutConstraint.Orientation, NSLayoutConstraint.Priority, NSLayoutConstraint.Priority)]

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
        lineBreakStrategy = field.lineBreakStrategy
        isSelectable = field.isSelectable
        priorities = [NSLayoutConstraint.Orientation.horizontal, .vertical].map {
            ($0, field.contentHuggingPriority(for: $0), field.contentCompressionResistancePriority(for: $0))
        }
    }
}

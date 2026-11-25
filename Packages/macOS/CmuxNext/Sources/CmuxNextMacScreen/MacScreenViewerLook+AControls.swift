import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextDevices

// Look A's controls (``MacScreenViewerStyle/lookA``): the picture's corner pill and the toolbar's View | Control segments.

/// A small glass pill in the picture's corner: who holds the keyboard (and how to release it), View Only, or Reconnecting.
@MainActor
final class MacScreenPictureMark: NSView {
    enum Kind { case controlling, viewOnly, reconnecting }

    static let height: CGFloat = 24
    /// A stall over the picture says Reconnecting only once it has lasted the shared connection bound (Leo,
    /// 2026-11-21: "stop layout shifting"; the pill is an overlay in the picture's corner, so it never moves the
    /// picture): ``NoticeTiming/connectionQuiet``, not the 1 s it waited before.
    static let reconnectingDelay = NoticeTiming.connectionQuiet
    private let surface = MacScreenLookA.glass(cornerRadius: MacScreenPictureMark.height / 2) // radius-allow: the pill is a capsule
    private let rows: [Kind: NSStackView]
    private var kind: Kind?

    init() {
        let caption = MacScreenType.caption
        let keys = L.t("macScreen.toolbar.keyboardHint", "Keyboard goes to this Mac · ⌃⌥⎋ to release")
        rows = [
            .controlling: MacScreenStack.make(.horizontal, spacing: Metrics.space3, alignment: .centerY, [
                Self.dot(\.focus),
                MacScreenText(L.t("macScreen.viewer.controlling", "Controlling"), font: caption),
                MacScreenText("⌃⌥⎋", font: caption, ink: \.tertiary), // Keycaps, as macOS prints them in every language.
            ]),
            .viewOnly: MacScreenStack.make(.horizontal, spacing: Metrics.space3, alignment: .centerY, [
                MacScreenGlyph("eye", font: caption, ink: \.attention),
                MacScreenText(L.t("macScreen.scope.view", "View Only"), font: caption, ink: \.secondary),
            ]),
            .reconnecting: MacScreenStack.make(.horizontal, spacing: Metrics.space3, alignment: .centerY, [
                Self.dot(\.attention),
                MacScreenText(L.t("macScreen.card.reconnecting", "Reconnecting…"), font: caption, ink: \.secondary),
            ]),
        ]
        super.init(frame: .zero)
        addSubview(surface)
        for row in rows.values {
            row.translatesAutoresizingMaskIntoConstraints = true
            row.isHidden = true
            addSubview(row)
        }
        rows[.controlling]?.setAccessibilityLabel(keys)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static func dot(_ fill: KeyPath<MacScreenColors, NSColor>) -> NSView {
        let dot = MacScreenFill(fill, shape: .circle)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: Metrics.space3),
            dot.heightAnchor.constraint(equalToConstant: Metrics.space3),
        ])
        return dot
    }

    func show(_ kind: Kind) {
        isHidden = false
        guard kind != self.kind else { return }
        self.kind = kind
        for (rowKind, row) in rows {
            row.isHidden = rowKind != kind
            row.setAccessibilityElement(rowKind == kind)
        }
        needsLayout = true
    }

    override var fittingSize: NSSize {
        guard let kind, let row = rows[kind] else { return .zero }
        return NSSize(width: ceil(row.fittingSize.width) + Metrics.space5 * 2, height: Self.height)
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        guard let kind, let row = rows[kind] else { return }
        let size = row.fittingSize
        row.frame = CGRect(x: Metrics.space5, y: (bounds.height - size.height) / 2, width: bounds.width - Metrics.space5 * 2,
                           height: size.height).integral
    }
}

/// Look A's scope control: View | Control on a faint track, the chosen segment on the selection fill. Choosing the other
/// segment asks the hub for that scope; the selection follows the session (``select(_:)``), never the click.
@MainActor
final class MacScreenScopeSegments: NSView, MacScreenInked {
    static let inset: CGFloat = 2
    static let height: CGFloat = 22
    private let segments: [MacScreenScopeSegment]
    private(set) var selected: SessionScope?

    init(onChoose: @escaping @MainActor (SessionScope) -> Void) {
        segments = [
            MacScreenScopeSegment(L.t("macScreen.viewer.segment.view", "View"), scope: .view, symbol: "eye"),
            MacScreenScopeSegment(L.t("macScreen.viewer.segment.control", "Control"), scope: .full, symbol: "cursorarrow"),
        ]
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Metrics.buttonCornerRadius
        layer?.cornerCurve = .continuous
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityIdentifier("macScreen.scopeSegments")
        for segment in segments {
            segment.onPress = { [weak self, scope = segment.scope] in
                guard let self, selected != scope else { return }
                onChoose(scope)
            }
            addSubview(segment)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// The segments' words (View, Control) beside their glyphs; off, each segment is its glyph, its word the tooltip.
    var showsTitles = true {
        didSet {
            guard showsTitles != oldValue else { return }
            for segment in segments { segment.showsTitle = showsTitles }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    func select(_ scope: SessionScope) {
        selected = scope
        for segment in segments { segment.isSelected = segment.scope == scope }
    }

    func apply(_ colors: MacScreenColors) {
        layer?.backgroundColor = colors.hover.cgColor
    }

    override var intrinsicContentSize: NSSize {
        let width = segments.reduce(Self.inset * 2) { $0 + $1.intrinsicContentSize.width }
        return NSSize(width: ceil(width), height: Self.height)
    }

    override var fittingSize: NSSize { intrinsicContentSize }

    override func layout() {
        super.layout()
        var x = Self.inset
        for segment in segments {
            let width = segment.intrinsicContentSize.width
            segment.frame = CGRect(x: x, y: Self.inset, width: width, height: bounds.height - Self.inset * 2)
            x += width
        }
    }
}

/// One segment of ``MacScreenScopeSegments``: selected on the selection fill, hover and pressed fills only.
@MainActor
final class MacScreenScopeSegment: NSButton, MacScreenInked {
    let scope: SessionScope
    var onPress: () -> Void = {}
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            setAccessibilityValue(NSNumber(value: isSelected))
            refresh()
        }
    }
    /// The word beside the glyph; off, the word is the tooltip.
    var showsTitle = true {
        didSet {
            guard showsTitle != oldValue else { return }
            themedToolTip = showsTitle ? nil : text
            refresh()
        }
    }
    private let text: String
    private var colors = MacScreenColors()
    private var hovering = false { didSet { if hovering != oldValue { refresh() } } }
    private var tracking: NSTrackingArea?

    init(_ title: String, scope: SessionScope, symbol: String) {
        self.scope = scope
        text = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = true
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerCurve = .continuous
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imagePosition = .imageLeading
        imageHugsTitle = true
        target = self
        action = #selector(pressed)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        setAccessibilityValue(NSNumber(value: false))
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func pressed() { onPress() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isHighlighted: Bool { didSet { refresh() } }

    func apply(_ colors: MacScreenColors) {
        self.colors = colors
        refresh()
    }

    override var intrinsicContentSize: NSSize {
        let title = attributedTitle.size()
        let glyph = image?.size.width ?? 0
        guard showsTitle else { return NSSize(width: ceil(glyph + Metrics.space4 * 2), height: ceil(max(title.height, 16))) }
        return NSSize(width: ceil(title.width + glyph + Metrics.space2 + Metrics.space4 * 2), height: ceil(max(title.height, 16)))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hovering = false }
    }

    private var fill: NSColor {
        if isHighlighted { return colors.pressed }
        if isSelected { return colors.selection }
        return hovering ? colors.hover : .clear
    }

    private func refresh() {
        layer?.backgroundColor = fill.cgColor
        layer?.cornerRadius = Metrics.buttonCornerRadius(nestedIn: Metrics.buttonCornerRadius, inset: MacScreenScopeSegments.inset)
        let ink = isSelected ? colors.primary : colors.secondary
        let font = MacScreenType.body
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: font.pointSize - 1, weight: .regular)
        contentTintColor = ink
        attributedTitle = NSAttributedString(string: showsTitle ? text : "", attributes: [.foregroundColor: ink, .font: font])
        imagePosition = showsTitle ? .imageLeading : .imageOnly
        invalidateIntrinsicContentSize()
    }
}

/// The stats panel (``MacScreenQualityReadout/hud``): a glass panel in the picture's bottom-left corner, one number per
/// line (rate, frames of target, round trip, loss, encode, codec, size), labels in the tertiary ink.
@MainActor
final class MacScreenStatsPanel: MacScreenThemedView {
    private let surface = MacScreenLookA.glass(cornerRadius: Metrics.space4) // radius-allow: a floating panel, the picture mark's family
    private let text = NSTextField(labelWithString: "")
    private var rows: [(label: String, value: String)] = []
    private var strained = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(surface)
        text.translatesAutoresizingMaskIntoConstraints = true
        text.maximumNumberOfLines = 0
        text.usesSingleLineMode = false
        text.cell?.wraps = false
        addSubview(text)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L.t("macScreen.readout.panel", "Stream stats"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows these rows; `strained` marks the rate in the attention ink.
    func show(_ rows: [(label: String, value: String)], strained: Bool) {
        let same = rows.count == self.rows.count && zip(rows, self.rows).allSatisfy { $0.label == $1.label && $0.value == $1.value }
        guard !same || strained != self.strained else { return }
        self.rows = rows
        self.strained = strained
        paint()
        needsLayout = true
    }

    override func colorsChanged() {
        super.colorsChanged()
        paint()
    }

    private func paint() {
        let font = MacScreenType.stats
        let labelWidth = rows.map { ceil(($0.label as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: labelWidth + Metrics.space4)]
        style.lineSpacing = Metrics.space1
        let out = NSMutableAttributedString()
        let rateLabel = MacScreenQualityReadout.rateLabel
        for (index, row) in rows.enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(NSAttributedString(string: row.label + "\t", attributes: [.font: font, .foregroundColor: colors.tertiary, .paragraphStyle: style]))
            let ink = strained && row.label == rateLabel ? colors.attention : colors.primary
            out.append(NSAttributedString(string: row.value, attributes: [.font: font, .foregroundColor: ink, .paragraphStyle: style]))
        }
        text.attributedStringValue = out
        setAccessibilityValue(rows.map { "\($0.label) \($0.value)" }.joined(separator: ", "))
    }

    override var fittingSize: NSSize {
        let size = text.attributedStringValue.boundingRect(with: NSSize(width: 1000, height: 1000), options: [.usesLineFragmentOrigin]).size
        return NSSize(width: ceil(size.width) + Metrics.space4 * 2 + 4, height: ceil(size.height) + Metrics.space3 * 2)
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        text.frame = bounds.insetBy(dx: Metrics.space4, dy: Metrics.space3)
    }
}

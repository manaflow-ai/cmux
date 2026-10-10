import AppKit
import CmuxNextDesign

/// The "cmux Updated!" card above the footer (cx-7py7), in the tip card's
/// slot and on its material: the title centered with an x, a hairline, then
/// two rows, "See What's New" and "Share cmux". Liquid Glass with the
/// theme's glass tint (opaque under Reduce Transparency), the lines in a
/// sibling above the material like the tip card (cx-367y). Hidden without
/// a card.
final class SidebarUpdatedCardView: NSView {
    private(set) var card: SidebarUpdatedCard?
    private let titleLabel = NSTextField(labelWithString: "")
    private let divider = NSView()
    /// After an update: the build date and the first changelog lines.
    private var infoLabels: [NSTextField] = []
    let whatsNewRow = SidebarUpdatedCardRow(symbol: "sparkles")
    let shareRow = SidebarUpdatedCardRow(symbol: "square.and.arrow.up")
    let closeButton = SidebarIconButton(symbol: "xmark", pointSize: { 9 }, label: "")
    /// The card's material: Liquid Glass, or opaque under Reduce Transparency.
    let surface: OverlaySurfaceView
    /// The lines and rows, flipped, over the surface.
    private let content = SidebarUpdatedCardContent()

    init(frame: NSRect = .zero, reduceTransparency: ReduceTransparency = .shared) {
        surface = OverlaySurfaceView(interactive: true, cornerRadius: Metrics.space3, reduceTransparency: reduceTransparency)
        super.init(frame: frame)
        surface.translatesAutoresizingMaskIntoConstraints = true
        addSubview(surface)
        addSubview(content)
        content.material = { [weak surface] in surface?.material ?? .liquidGlass }
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        divider.wantsLayer = true
        [titleLabel, divider, whatsNewRow, shareRow, closeButton].forEach(content.addSubview)
        setAccessibilityElement(false)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Shows `card`, or hides the view for nil.
    func configure(_ card: SidebarUpdatedCard?) {
        guard card != self.card else { return }
        self.card = card
        isHidden = card == nil
        guard let card else { return }
        titleLabel.stringValue = card.title
        infoLabels.forEach { $0.removeFromSuperview() }
        infoLabels = Self.infoLines(card).map { line in
            let label = NSTextField(labelWithString: line)
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.toolTip = line
            content.addSubview(label)
            return label
        }
        whatsNewRow.text = card.whatsNewTitle
        shareRow.text = card.shareTitle
        closeButton.label = card.dismissLabel
        needsLayout = true
        applyColors()
    }

    // MARK: Geometry

    private static var padding: CGFloat { Metrics.space2 }
    private static var titleHeight: CGFloat { ceil(Typography.bodyEmphasized.boundingRectForFont.height) + 2 * Metrics.space2 }
    static var rowHeight: CGFloat { ceil(Typography.body.boundingRectForFont.height) + 2 * Metrics.space2 }

    private static var captionHeight: CGFloat { ceil(Typography.caption.boundingRectForFont.height) }
    /// Changelog lines the card shows.
    static let maxLines = 4

    /// The detail and changelog lines as shown ("• " before each change).
    static func infoLines(_ card: SidebarUpdatedCard) -> [String] {
        (card.detail.map { [$0] } ?? []) + card.lines.prefix(maxLines).map { "• " + $0 }
    }

    /// The title band, the hairline, the update's lines when present, two rows.
    static func height(for card: SidebarUpdatedCard) -> CGFloat {
        let lines = CGFloat(infoLines(card).count)
        return ceil(titleHeight + 1 + Metrics.space1 + (lines > 0 ? lines * captionHeight + Metrics.space1 : 0) + 2 * rowHeight + padding)
    }

    override func layout() {
        super.layout()
        let b = bounds, pad = Self.padding
        surface.frame = b
        surface.cornerRadius = Metrics.space3
        content.layer?.cornerRadius = Metrics.space3
        content.layer?.cornerCurve = .continuous
        content.frame = b
        titleLabel.font = Typography.bodyEmphasized
        let close: CGFloat = 16, titleHeight = Self.titleHeight
        closeButton.frame = NSRect(x: b.width - pad - close, y: (titleHeight - close) / 2, width: close, height: close)
        let lineHeight = ceil(Typography.bodyEmphasized.boundingRectForFont.height)
        titleLabel.frame = NSRect(x: pad + close, y: (titleHeight - lineHeight) / 2, width: max(0, b.width - 2 * (pad + close)),
                                  height: lineHeight)
        divider.frame = NSRect(x: 0, y: titleHeight, width: b.width, height: 1)
        let rowWidth = max(0, b.width - 2 * pad)
        var y = divider.frame.maxY + Metrics.space1
        for label in infoLabels {
            label.font = Typography.caption
            label.frame = NSRect(x: pad + Metrics.space2, y: y, width: max(0, rowWidth - Metrics.space2), height: Self.captionHeight)
            y += Self.captionHeight
        }
        if !infoLabels.isEmpty { y += Metrics.space1 }
        whatsNewRow.frame = NSRect(x: pad, y: y, width: rowWidth, height: Self.rowHeight)
        shareRow.frame = NSRect(x: pad, y: whatsNewRow.frame.maxY, width: rowWidth, height: Self.rowHeight)
    }

    private func applyColors() {
        performWithTheme {
            titleLabel.textColor = Palette.textPrimary
            divider.layer?.backgroundColor = Palette.separator.cgColor
            for label in infoLabels { label.textColor = Palette.textSecondary }
        }
        whatsNewRow.refresh()
        shareRow.refresh()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        surface.applyTheme()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    // MARK: Tests

    /// Every line as shown, top to bottom.
    var shownText: [String] { [titleLabel.stringValue] + infoLabels.map(\.stringValue) + [whatsNewRow.text, shareRow.text] }
}

/// One row of the "cmux Updated!" card: a symbol and a title, the hover
/// fill of the sidebar's other controls, pressed by a click (VoiceOver:
/// a button named by its title).
final class SidebarUpdatedCardRow: NSButton {
    private(set) lazy var hover = ChromeHover(self, behindContent: true)
    var onPress: (() -> Void)?
    private let symbol: String
    /// The row's title as shown.
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            setAccessibilityLabel(text)
            refresh()
        }
    }

    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageLeading
        imageHugsTitle = true
        alignment = .natural
        wantsLayer = true
        target = self
        action = #selector(pressed)
        refusesFirstResponder = true
        setAccessibilityRole(.button)
        hover.followPointer(onChange: { [weak self] in self?.refresh() })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pressed() { onPress?() }

    /// Symbol and title in the hover state's color.
    func refresh() {
        performWithTheme {
            let color = hover.state.hovering || hover.state.pressed ? Palette.textPrimary : Palette.textSecondary
            let config = NSImage.SymbolConfiguration(pointSize: Metrics.smallIconSize, weight: .regular)
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            contentTintColor = color
            // A leading space separates the title from the symbol (imageHugsTitle).
            attributedTitle = NSAttributedString(string: " " + text, attributes: [.font: Typography.body, .foregroundColor: color])
        }
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = Metrics.itemCornerRadius
        hover.refresh(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    /// NSButton tracks the click inside `super.mouseDown` and returns on release.
    override func mouseDown(with event: NSEvent) {
        hover.state.pressed = true
        refresh()
        super.mouseDown(with: event)
        hover.state.pressed = false
        refresh()
    }

    /// A row hidden under the pointer (the card going away) gets no exit event.
    override func viewDidHide() {
        super.viewDidHide()
        hover.state.pressed = false
        hover.pointer?.refresh()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        hover.pointer?.refresh()
    }
}

/// The card's lines, flipped, over the glass: the tip card's light theme
/// veil keeps them legible over a bright backdrop; the opaque fill needs none.
private final class SidebarUpdatedCardContent: NSView {
    var material: () -> OverlayMaterial = { .liquidGlass }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        performWithTheme {
            layer?.backgroundColor = material() == .opaque
                ? NSColor.clear.cgColor
                : Palette.elevatedBackground.withAlphaComponent(0.32).cgColor
        }
    }
}

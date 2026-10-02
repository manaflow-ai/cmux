import AppKit
import CmuxNextDesign

/// The current scope at the start of the search field (prototype styles
/// `PaletteScopeChipStyle`). Shows the top two levels above the root; a
/// click on a chip pops to the level below it, so the top chip leaves its
/// scope. Not in the key loop: the field keeps the keys (Tab is a palette
/// command), and VoiceOver reaches the chips as buttons.
final class PaletteScopeChipsView: NSView {
    /// Pops to level `index` (0 is the root).
    var onPopTo: ((Int) -> Void)?

    private var chips: [PaletteScopeChip] = []
    private var style: PaletteScopeChipStyle = .token
    private var chipViews: [PaletteScopeChipView] = []

    override var isFlipped: Bool { true }

    func update(chips: [PaletteScopeChip], style: PaletteScopeChipStyle) {
        let visible = Array(chips.suffix(2))
        guard visible != self.chips || style != self.style else { return }
        self.chips = visible
        self.style = style
        chipViews.forEach { $0.removeFromSuperview() }
        chipViews = visible.enumerated().map { offset, chip in
            let view = PaletteScopeChipView(chip: chip, style: style, isTop: offset == visible.count - 1)
            view.onClick = { [weak self] in self?.onPopTo?(chip.levelIndex - 1) }
            addSubview(view)
            return view
        }
        isHidden = visible.isEmpty
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Width the chips need at `height`.
    func fittingWidth(height: CGFloat) -> CGFloat {
        guard !chipViews.isEmpty else { return 0 }
        return chipViews.map { $0.fittingWidth }.reduce(0, +) + CGFloat(chipViews.count - 1) * Metrics.space2
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for view in chipViews {
            let width = min(view.fittingWidth, max(0, bounds.width - x))
            let height = view.preferredHeight
            view.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: width, height: height)
            x += width + Metrics.space2
        }
    }
}

/// One chip. `token`: a gray capsule; `header`: icon and semibold title
/// with a hairline after it.
final class PaletteScopeChipView: NSView {
    var onClick: (() -> Void)?

    private let chip: PaletteScopeChip
    private let style: PaletteScopeChipStyle
    private let isTop: Bool
    private let icon = NSImageView()
    private let label: PaletteLabel
    private let rule = NSView()

    init(chip: PaletteScopeChip, style: PaletteScopeChipStyle, isTop: Bool) {
        self.chip = chip
        self.style = style
        self.isTop = isTop
        label = PaletteText.label(style == .header ? Typography.bodyEmphasized : Typography.caption,
                                  tone: isTop ? .primary : .tertiary)
        super.init(frame: .zero)
        wantsLayer = true
        label.stringValue = chip.title
        icon.image = PaletteText.symbol(chip.symbol, size: Metrics.smallIconSize)
        rule.wantsLayer = true
        rule.isHidden = style != .header || !isTop
        [icon, label, rule].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(PaletteStrings.chipAccessibility(chip.title))
        toolTip = isTop ? PaletteStrings.chipAccessibility(chip.title) : PaletteStrings.backTo(chip.title)
        setAccessibilityIdentifier("palette.scopeChip.\(chip.scope.rawValue)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    var preferredHeight: CGFloat {
        style == .token ? label.intrinsicContentSize.height + Metrics.space2 * 2 : max(label.intrinsicContentSize.height, Metrics.iconSize)
    }

    var fittingWidth: CGFloat {
        let padding = style == .token ? Metrics.space3 * 2 : 0
        let ruleSpace = rule.isHidden ? 0 : Metrics.space4 + Metrics.dividerThickness
        return padding + Metrics.smallIconSize + Metrics.space2 + PaletteText.fittingWidth(label) + ruleSpace
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func layout() {
        super.layout()
        performWithTheme {
            icon.contentTintColor = isTop ? Palette.textSecondary : Palette.textTertiary
            rule.layer?.backgroundColor = Palette.separator.cgColor
            if style == .token {
                layer?.backgroundColor = (isTop ? Palette.selectionFill : Palette.selectionFill.withAlphaComponent(0.5)).cgColor
                layer?.cornerRadius = bounds.height / 2
            } else {
                layer?.backgroundColor = nil
            }
        }
        let inset = style == .token ? Metrics.space3 : 0
        let iconSize = Metrics.smallIconSize + Metrics.space1
        icon.frame = NSRect(x: inset, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        let labelHeight = label.intrinsicContentSize.height
        let ruleSpace = rule.isHidden ? 0 : Metrics.space4 + Metrics.dividerThickness
        let labelX = icon.frame.maxX + Metrics.space2
        label.frame = NSRect(x: labelX, y: (bounds.height - labelHeight) / 2, width: max(0, bounds.width - labelX - inset - ruleSpace),
                             height: labelHeight)
        let ruleHeight = Metrics.iconSize
        rule.frame = NSRect(x: bounds.width - Metrics.dividerThickness, y: (bounds.height - ruleHeight) / 2,
                            width: Metrics.dividerThickness, height: ruleHeight)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}

/// "Search Tabs ⇥" at the right of the field while the query is a scope's
/// keyword. A click enters the scope like Tab.
final class PaletteKeywordHintView: NSView {
    var onClick: (() -> Void)?
    private let label = PaletteText.label(Typography.caption, tone: .secondary)
    private let keys = PaletteKeycapsView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        keys.keycaps = ["⇥"]
        [label, keys].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func update(title: String?) {
        isHidden = title == nil
        let text = title.map(PaletteStrings.keywordHint) ?? ""
        label.stringValue = text
        setAccessibilityLabel(text)
        needsLayout = true
    }

    var fittingWidth: CGFloat { PaletteText.fittingWidth(label) + Metrics.space2 + keys.intrinsicContentSize.width }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func layout() {
        super.layout()
        let labelSize = NSSize(width: PaletteText.fittingWidth(label), height: label.intrinsicContentSize.height)
        let keySize = keys.intrinsicContentSize
        label.frame = NSRect(x: 0, y: (bounds.height - labelSize.height) / 2, width: labelSize.width, height: labelSize.height)
        keys.frame = NSRect(x: labelSize.width + Metrics.space2, y: (bounds.height - keySize.height) / 2, width: keySize.width, height: keySize.height)
    }
}

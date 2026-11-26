import AppKit
import CmuxNextDesign

/// Search header: the magnifier or the current scope (chip styles
/// `PaletteScopeChipStyle`), the query field, the keyword hint ("Search
/// Tabs ⇥") and a spinner while providers load.
final class PaletteSearchBar: NSView, NSTextFieldDelegate {
    let field = PaletteSearchField()
    var onQueryChange: ((String) -> Void)?
    /// Pops to level `index` (a click on a chip or the breadcrumb).
    var onPopTo: ((Int) -> Void)? {
        didSet { chips.onPopTo = onPopTo }
    }
    /// A click on the keyword hint (enters the scope, like Tab).
    var onKeywordHint: (() -> Void)? {
        didSet { keywordHint.onClick = onKeywordHint }
    }

    private let magnifier = NSImageView()
    private let chips = PaletteScopeChipsView()
    private let tokens = PaletteTokenChipsView()
    /// Takes out chosen value `index` (a click on its chip).
    var onRemoveToken: ((Int) -> Void)? {
        didSet { tokens.onRemove = onRemoveToken }
    }
    private let breadcrumb = PaletteClickView()
    // Secondary, not tertiary: the path is text you read (4.5:1), not a 3:1 mark.
    private let breadcrumbLabel = PaletteText.label(Typography.caption, tone: .secondary)
    private let keywordHint = PaletteKeywordHintView()
    /// The v2 look's "Esc" keycap at the field's right end (`PaletteV2Look.isOn`); a click closes the palette.
    private let escChip = PaletteEscChipView()
    var onEscChip: (() -> Void)? {
        didSet { escChip.onClick = onEscChip }
    }
    private let spinner = StatusIndicatorView.spinner()
    private var placeholder = ""
    /// The text width the placeholder was last fitted to.
    private var placeholderWidth: CGFloat = 0
    private var style: PaletteScopeChipStyle = .token
    private var depth = 0
    private var isLoading = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Typography.search
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        // An AX client reads the field through its cell (`PaletteSearchFieldCell`), so both carry its name.
        field.setAccessibilityIdentifier("palette.search")
        field.cell?.setAccessibilityIdentifier("palette.search")
        magnifier.image = PaletteText.symbol("magnifyingglass", size: Metrics.iconSize)
        breadcrumb.addSubview(breadcrumbLabel)
        breadcrumb.onClick = { [weak self] in
            guard let self, self.depth > 1 else { return }
            self.onPopTo?(self.depth - 2)
        }
        tokens.isHidden = true
        escChip.isHidden = true
        [magnifier, chips, breadcrumb, tokens, field, keywordHint, escChip, spinner].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    nonisolated override var isFlipped: Bool { true }

    /// `chips` are the levels above the root; `rootTitle` names the root
    /// in the breadcrumb.
    func update(query: String, placeholder: String, chips scopeChips: [PaletteScopeChip], rootTitle: String,
                style: PaletteScopeChipStyle, keywordHint hint: String?, isLoading: Bool,
                tokens chosen: [(title: String, symbol: String)] = [], showsEscChip: Bool = false) {
        tokens.update(chips: chosen)
        if escChip.isHidden == showsEscChip {
            escChip.isHidden = !showsEscChip
            needsLayout = true
        }
        if field.stringValue != query {
            field.stringValue = query
            // Keep a caret at the end instead of a selection.
            field.currentEditor()?.selectedRange = NSRange(location: query.utf16.count, length: 0)
        }
        // The placeholder carries its own font, so a text size change redraws it too (#26606).
        if placeholder != self.placeholder || field.placeholderAttributedString == nil || field.font != Typography.search {
            self.placeholder = placeholder
            field.font = Typography.search
            applyColors()
        }
        self.style = style
        depth = scopeChips.count + 1
        let showsChips = style != .breadcrumb && !scopeChips.isEmpty
        chips.update(chips: showsChips ? scopeChips : [], style: style)
        magnifier.isHidden = showsChips
        breadcrumb.isHidden = style != .breadcrumb || scopeChips.isEmpty
        breadcrumbLabel.stringValue = ([rootTitle] + scopeChips.map(\.title)).joined(separator: " › ")
        breadcrumb.themedToolTip = scopeChips.dropLast().last.map { PaletteStrings.backTo($0.title) } ?? PaletteStrings.backTo(rootTitle)
        keywordHint.update(title: hint)
        let name = scopeChips.last.map { PaletteStrings.keywordHint($0.title) } ?? placeholder
        field.setAccessibilityLabel(name)
        field.cell?.setAccessibilityLabel(name)
        spinner.spin(isLoading)
        self.isLoading = isLoading
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            magnifier.contentTintColor = Palette.textTertiary
            // The field scrolls its text, and a scrolling cell clips a placeholder wider than the
            // field mid-glyph whatever its line break mode, so it is cut to fit here, with an
            // ellipsis (#26606).
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [.font: Typography.search, .foregroundColor: Palette.textSecondary,
                                                             .paragraphStyle: style]
            field.placeholderAttributedString = NSAttributedString(
                string: Self.fitted(placeholder, width: placeholderWidth, attributes: attributes),
                attributes: attributes
            )
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        onQueryChange?(field.stringValue)
    }

    override func layout() {
        super.layout()
        let padding = PaletteLayout.horizontalPadding
        var x = padding
        let fieldHeight = PaletteText.height(field)
        var fieldY = (bounds.height - fieldHeight) / 2
        if !breadcrumb.isHidden {
            // Path above, field below, both inside the bar's height.
            let labelHeight = PaletteText.height(breadcrumbLabel)
            let total = labelHeight + fieldHeight
            let top = (bounds.height - total) / 2
            let width = min(PaletteText.fittingWidth(breadcrumbLabel), bounds.width - 2 * padding)
            breadcrumb.frame = pixelAligned(NSRect(x: padding + PaletteLayout.iconBox + Metrics.space4, y: top, width: width, height: labelHeight))
            breadcrumbLabel.frame = breadcrumb.bounds
            fieldY = top + labelHeight
        }
        if !magnifier.isHidden {
            let box = PaletteLayout.iconBox
            magnifier.frame = NSRect(x: x, y: fieldY + (fieldHeight - box) / 2, width: box, height: box)
            x = magnifier.frame.maxX + Metrics.space4
        }
        if !chips.isHidden {
            let width = min(chips.fittingWidth(height: bounds.height), bounds.width / 2)
            chips.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            x = chips.frame.maxX + Metrics.space4
        }
        if !tokens.isHidden {
            // At most 60% of the bar, so the query always has room to type the next name.
            let width = min(tokens.fittingWidth, max(0, (bounds.width - x - padding) * 0.6))
            tokens.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            x = tokens.frame.maxX + Metrics.space4
        }
        // The hint ends on the rows' right edge (``PaletteLayout/trailingInset``), where their keys
        // and kind labels end; a spinner takes the edge only with no hint, else it sits left of the
        // hint, so the hint never moves while results load.
        var right = bounds.maxX - PaletteLayout.trailingInset
        // The v2 look's Esc chip takes the edge; the hint and the spinner sit left of it.
        if !escChip.isHidden {
            let size = escChip.intrinsicContentSize
            escChip.frame = pixelAligned(NSRect(x: right - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
            right = escChip.frame.minX - Metrics.space4
        }
        if !keywordHint.isHidden {
            let width = keywordHint.fittingWidth
            keywordHint.frame = pixelAligned(NSRect(x: right - width, y: 0, width: width, height: bounds.height))
            right = keywordHint.frame.minX - Metrics.space4
        }
        let spinnerSize = PaletteLayout.iconBox
        let glyphInset = (spinnerSize - Metrics.iconSize) / 2
        spinner.frame = NSRect(x: right + glyphInset - spinnerSize, y: (bounds.height - spinnerSize) / 2,
                               width: spinnerSize, height: spinnerSize)
        if isLoading { right = spinner.frame.minX + glyphInset - Metrics.space4 }
        field.frame = pixelAligned(NSRect(x: x, y: fieldY, width: max(0, right - x), height: fieldHeight))
        // Less the field editor's line fragment padding (2 pt a side), which the text draws inside.
        let textWidth = (field.cell?.titleRect(forBounds: field.bounds).width ?? field.bounds.width) - 4
        if textWidth != placeholderWidth {
            placeholderWidth = textWidth
            applyColors()
        }
    }

    /// `text` whole when it fits `width`, else its longest prefix that fits with an ellipsis.
    static func fitted(_ text: String, width: CGFloat, attributes: [NSAttributedString.Key: Any]) -> String {
        func fits(_ candidate: String) -> Bool {
            (candidate as NSString).size(withAttributes: attributes).width <= width
        }
        guard width > 0, !fits(text) else { return text }
        let characters = Array(text)
        var low = 0
        var high = characters.count
        while low < high {
            let mid = (low + high + 1) / 2
            if fits(Self.truncated(characters, mid)) { low = mid } else { high = mid - 1 }
        }
        return Self.truncated(characters, low)
    }

    private static func truncated(_ characters: [Character], _ count: Int) -> String {
        String(characters.prefix(count)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// The v2 look's "Esc" keycap at the right end of the field (the reference's command menu): a click closes the
/// palette. It draws the rows' keycap and changes nothing while held.
final class PaletteEscChipView: NSView {
    var onClick: (() -> Void)?
    private let keys = PaletteKeycapsView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        keys.keycaps = [PaletteStrings.escKey]
        addSubview(keys)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(PaletteStrings.closePalette)
        setAccessibilityIdentifier("palette.escChip")
        themedToolTip = PaletteStrings.closePalette
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    nonisolated override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { keys.intrinsicContentSize }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func layout() {
        super.layout()
        keys.frame = bounds
    }
}

/// The v2 scope bar under the field (`PaletteV2Look.scoped`): All, This Workspace and Sessions in a soft track, the
/// chosen one a filled pill (the segmented scope bar pattern). A click, or Cmd-1 to Cmd-3, picks one.
final class PaletteScopeBarView: NSView {
    var onChoose: ((PaletteScopeSegment) -> Void)?
    private var buttons: [PaletteClickView] = []
    private var labels: [PaletteLabel] = []
    private var selected: PaletteScopeSegment?

    override init(frame: NSRect) {
        super.init(frame: frame)
        for segment in PaletteScopeSegment.allCases {
            let button = PaletteClickView()
            let label = PaletteText.label(Typography.caption, tone: .secondary)
            label.alignment = .center
            label.stringValue = segment.title
            button.addSubview(label)
            button.onClick = { [weak self] in self?.onChoose?(segment) }
            button.setAccessibilityElement(true)
            button.setAccessibilityRole(.radioButton)
            button.setAccessibilityLabel(segment.title)
            button.setAccessibilityIdentifier("palette.scopeBar.\(segment)")
            addSubview(button)
            buttons.append(button)
            labels.append(label)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityIdentifier("palette.scopeBar")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    nonisolated override var isFlipped: Bool { true }

    func update(selected segment: PaletteScopeSegment) {
        guard segment != selected else { return }
        selected = segment
        for (index, button) in buttons.enumerated() {
            let isOn = index == segment.rawValue
            button.fillsBackground = isOn
            labels[index].tone = isOn ? .primary : .secondary
            button.setAccessibilityValue(isOn)
        }
    }

    /// The track: inside the field's side padding, as tall as a keycap row with room around it.
    private var trackRect: NSRect {
        let padding = PaletteLayout.horizontalPadding
        let height = min(bounds.height - Metrics.space2 * 2, PaletteLayout.keycapSize + Metrics.space2 * 2)
        let width = max(0, min(bounds.width, PaletteLayout.listWidth) - 2 * padding)
        return NSRect(x: padding, y: (bounds.height - height) / 2, width: width, height: max(0, height))
    }

    override func layout() {
        super.layout()
        let track = trackRect
        let inset = Metrics.space1
        let count = CGFloat(max(1, buttons.count))
        let width = (track.width - inset * 2) / count
        for (index, button) in buttons.enumerated() {
            button.frame = pixelAligned(NSRect(x: track.minX + inset + width * CGFloat(index), y: track.minY + inset,
                                               width: width, height: track.height - inset * 2))
            let label = labels[index]
            let height = PaletteText.height(label)
            label.frame = button.pixelAligned(NSRect(x: 0, y: (button.bounds.height - height) / 2, width: button.bounds.width, height: height))
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = trackRect
        guard track.width > 0, track.height > 0 else { return }
        performWithTheme {
            Palette.hoverFill.setFill()
            let radius = Metrics.buttonCornerRadius(fitting: track.size)
            NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

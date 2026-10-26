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
    private let breadcrumb = PaletteClickView()
    // Secondary, not tertiary: the path is text you read (4.5:1), not a 3:1 mark.
    private let breadcrumbLabel = PaletteText.label(Typography.caption, tone: .secondary)
    private let keywordHint = PaletteKeywordHintView()
    private let spinner = StatusIndicatorView.spinner()
    private var placeholder = ""
    private var depth = 0
    /// The scope the bar shows, as last applied: a typed character changes none of it, so typing lays
    /// nothing out (the field's frame does not follow its text).
    private var shownScope: Scope?

    /// What `update` shows besides the query: the chips or breadcrumb, the keyword hint and the
    /// field's font, which `layout()` places.
    private struct Scope: Equatable {
        var chips: [PaletteScopeChip]
        var rootTitle: String
        var style: PaletteScopeChipStyle
        var keywordHint: String?
        var placeholder: String
        var font: NSFont
    }

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
        [magnifier, chips, breadcrumb, field, keywordHint, spinner].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    nonisolated override var isFlipped: Bool { true }

    /// `chips` are the levels above the root; `rootTitle` names the root
    /// in the breadcrumb.
    func update(query: String, placeholder: String, chips scopeChips: [PaletteScopeChip], rootTitle: String,
                style: PaletteScopeChipStyle, keywordHint hint: String?, isLoading: Bool) {
        if field.stringValue != query {
            field.stringValue = query
            // Keep a caret at the end instead of a selection.
            field.currentEditor()?.selectedRange = NSRange(location: query.utf16.count, length: 0)
        }
        if placeholder != self.placeholder || field.placeholderAttributedString == nil {
            self.placeholder = placeholder
            applyColors()
        }
        spinner.spin(isLoading)
        let scope = Scope(chips: scopeChips, rootTitle: rootTitle, style: style, keywordHint: hint, placeholder: placeholder,
                          font: Typography.search)
        guard scope != shownScope else { return }
        shownScope = scope
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
        if field.font != scope.font { field.font = scope.font }
        needsLayout = true // invalidate: a new scope, hint or font moves the chips, the hint and the field
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            magnifier.contentTintColor = Palette.textTertiary
            field.placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [.font: Typography.search, .foregroundColor: Palette.textTertiary]
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
        let spinnerSize = Metrics.iconSize + Metrics.space1 * 2
        spinner.frame = NSRect(x: bounds.maxX - padding - spinnerSize, y: (bounds.height - spinnerSize) / 2,
                               width: spinnerSize, height: spinnerSize)
        var right = spinner.frame.minX - Metrics.space4
        if !keywordHint.isHidden {
            let width = keywordHint.fittingWidth
            keywordHint.frame = pixelAligned(NSRect(x: right - width, y: 0, width: width, height: bounds.height))
            right = keywordHint.frame.minX - Metrics.space4
        }
        field.frame = pixelAligned(NSRect(x: x, y: fieldY, width: max(0, right - x), height: fieldHeight))
    }
}

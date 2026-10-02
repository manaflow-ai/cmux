import AppKit
import CmuxNextDesign

/// A borderless clickable region (footer hints, the back chip).
final class PaletteClickView: NSView {
    var onClick: (() -> Void)?
    var fillsBackground = false {
        didSet { needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard fillsBackground else { return }
        performWithTheme {
            Palette.selectionFill.setFill()
            let radius = bounds.height / 2
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
    }
}

/// Search header: back chip (nested pages) or magnifier, the query field,
/// and a spinner while providers load.
final class PaletteSearchBar: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    var onQueryChange: ((String) -> Void)?
    var onBack: (() -> Void)?

    private let magnifier = NSImageView()
    private let backChip = PaletteClickView()
    private let backLabel = PaletteText.label(Typography.caption, tone: .secondary)
    private let spinner = NSProgressIndicator()
    private var placeholder = ""

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
        field.setAccessibilityIdentifier("palette.search")
        magnifier.image = PaletteText.symbol("magnifyingglass", size: Metrics.iconSize)
        backChip.fillsBackground = true
        backChip.onClick = { [weak self] in self?.onBack?() }
        backChip.addSubview(backLabel)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        [magnifier, backChip, field, spinner].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(query: String, placeholder: String, breadcrumb: String?, isLoading: Bool) {
        if field.stringValue != query {
            field.stringValue = query
            // Keep a caret at the end instead of a selection.
            field.currentEditor()?.selectedRange = NSRange(location: query.utf16.count, length: 0)
        }
        if placeholder != self.placeholder || field.placeholderAttributedString == nil {
            self.placeholder = placeholder
            applyColors()
        }
        backChip.isHidden = breadcrumb == nil
        magnifier.isHidden = breadcrumb != nil
        backLabel.stringValue = breadcrumb.map { "‹ \($0)" } ?? ""
        field.font = Typography.search
        if isLoading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        needsLayout = true
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
        if backChip.isHidden {
            let box = PaletteLayout.iconBox
            magnifier.frame = NSRect(x: x, y: (bounds.height - box) / 2, width: box, height: box)
            x = magnifier.frame.maxX + Metrics.space4
        } else {
            let labelSize = NSSize(width: PaletteText.fittingWidth(backLabel), height: backLabel.intrinsicContentSize.height)
            let height = labelSize.height + Metrics.space2 * 2
            let width = min(labelSize.width + Metrics.space4 * 2, bounds.width / 3)
            backChip.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: width, height: height)
            backLabel.frame = NSRect(x: Metrics.space4, y: Metrics.space2, width: width - Metrics.space4 * 2, height: labelSize.height)
            x = backChip.frame.maxX + Metrics.space4
        }
        let spinnerSize = Metrics.iconSize + Metrics.space1 * 2
        spinner.frame = NSRect(x: bounds.maxX - padding - spinnerSize, y: (bounds.height - spinnerSize) / 2,
                               width: spinnerSize, height: spinnerSize)
        let fieldHeight = field.intrinsicContentSize.height
        field.frame = NSRect(x: x, y: (bounds.height - fieldHeight) / 2, width: spinner.frame.minX - Metrics.space4 - x, height: fieldHeight)
    }
}

/// Footer: current page on the left; the row's close command with Cmd-W
/// (when it has one), the primary action with Return and "Actions ⌘K" on
/// the right, all clickable.
final class PaletteFooterView: NSView {
    var onPrimary: (() -> Void)?
    var onActions: (() -> Void)?
    var onClose: (() -> Void)?

    private let pageIcon = NSImageView()
    private let pageLabel = PaletteText.label(Typography.caption, tone: .secondary)
    private let primaryButton = PaletteClickView()
    private let primaryLabel = PaletteText.label(Typography.bodyEmphasized)
    private let primaryKeys = PaletteKeycapsView()
    private let divider = NSView()
    private let actionsButton = PaletteClickView()
    private let actionsLabel = PaletteText.label(Typography.caption, tone: .secondary)
    private let actionsKeys = PaletteKeycapsView()
    private let closeButton = PaletteClickView()
    private let closeLabel = PaletteText.label(Typography.caption, tone: .secondary)
    private let closeKeys = PaletteKeycapsView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        closeKeys.keycaps = ["⌘", "W"]
        closeButton.onClick = { [weak self] in self?.onClose?() }
        closeButton.addSubview(closeLabel)
        closeButton.addSubview(closeKeys)
        closeButton.isHidden = true
        primaryKeys.keycaps = ["↩"]
        actionsKeys.keycaps = ["⌘", "K"]
        actionsLabel.stringValue = PaletteStrings.actions
        divider.wantsLayer = true
        primaryButton.onClick = { [weak self] in self?.onPrimary?() }
        actionsButton.onClick = { [weak self] in self?.onActions?() }
        primaryButton.addSubview(primaryLabel)
        primaryButton.addSubview(primaryKeys)
        actionsButton.addSubview(actionsLabel)
        actionsButton.addSubview(actionsKeys)
        [pageIcon, pageLabel, closeButton, primaryButton, divider, actionsButton].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(pageTitle: String, pageSymbol: String, primaryTitle: String?, actionsEnabled: Bool, closeTitle: String? = nil) {
        closeLabel.stringValue = closeTitle ?? ""
        closeButton.isHidden = closeTitle == nil
        pageIcon.image = PaletteText.symbol(pageSymbol, size: Metrics.smallIconSize)
        pageLabel.stringValue = pageTitle
        primaryLabel.stringValue = primaryTitle ?? ""
        primaryButton.isHidden = primaryTitle == nil
        divider.isHidden = primaryTitle == nil
        actionsButton.alphaValue = actionsEnabled ? 1 : 0.4
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        performWithTheme {
            pageIcon.contentTintColor = Palette.textSecondary
            divider.layer?.backgroundColor = Palette.separator.cgColor
        }
        let padding = PaletteLayout.horizontalPadding
        let midY = bounds.midY
        let iconBox = Metrics.smallIconSize + Metrics.space1 * 2
        pageIcon.frame = NSRect(x: padding, y: midY - iconBox / 2, width: iconBox, height: iconBox)
        var right = bounds.maxX - padding
        right = layoutButton(actionsButton, label: actionsLabel, keys: actionsKeys, right: right)
        if !primaryButton.isHidden {
            right -= Metrics.space4
            let dividerHeight = Metrics.iconSize
            divider.frame = NSRect(x: right - Metrics.dividerThickness, y: midY - dividerHeight / 2,
                                   width: Metrics.dividerThickness, height: dividerHeight)
            right -= Metrics.dividerThickness + Metrics.space4
            right = layoutButton(primaryButton, label: primaryLabel, keys: primaryKeys, right: right)
        }
        if !closeButton.isHidden {
            right -= Metrics.space5
            right = layoutButton(closeButton, label: closeLabel, keys: closeKeys, right: right)
        }
        let labelX = pageIcon.frame.maxX + Metrics.space3
        let height = pageLabel.intrinsicContentSize.height
        pageLabel.frame = NSRect(x: labelX, y: midY - height / 2, width: max(0, right - Metrics.space4 - labelX), height: height)
    }

    private func layoutButton(_ button: NSView, label: NSTextField, keys: PaletteKeycapsView, right: CGFloat) -> CGFloat {
        let labelSize = NSSize(width: PaletteText.fittingWidth(label), height: label.intrinsicContentSize.height)
        let keySize = keys.intrinsicContentSize
        let width = labelSize.width + Metrics.space3 + keySize.width
        let height = max(labelSize.height, keySize.height)
        button.frame = NSRect(x: right - width, y: bounds.midY - height / 2, width: width, height: height)
        label.frame = NSRect(x: 0, y: (height - labelSize.height) / 2, width: labelSize.width, height: labelSize.height)
        keys.frame = NSRect(x: labelSize.width + Metrics.space3, y: (height - keySize.height) / 2, width: keySize.width, height: keySize.height)
        return button.frame.minX
    }
}

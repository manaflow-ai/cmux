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

/// Footer: current page on the left; the row's close command with Cmd-W
/// (when it has one), the primary action with Return and "Actions ⇥" on
/// the right, all clickable.
final class PaletteFooterView: NSView {
    var onPrimary: (() -> Void)?
    var onActions: (() -> Void)?
    var onClose: (() -> Void)?
    /// A click on footer segment `index` (`PalettePageSpec.crumbs`).
    var onCrumb: ((Int) -> Void)?
    private var crumbs: [(button: PaletteClickView, label: NSTextField)] = []

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
        actionsKeys.keycaps = ["⇥"]
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

    func update(pageTitle: String, pageSymbol: String, primaryTitle: String?, actionsEnabled: Bool, closeTitle: String? = nil,
                crumbs titles: [String] = []) {
        if titles != crumbs.map(\.label.stringValue) { setCrumbs(titles) }
        pageLabel.isHidden = !titles.isEmpty
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
        if !crumbs.isEmpty { layoutCrumbs(from: labelX, to: right - Metrics.space4) }
    }

    private func setCrumbs(_ titles: [String]) {
        crumbs.forEach { $0.button.removeFromSuperview() }
        crumbs = titles.enumerated().map { index, title in
            let button = PaletteClickView()
            let label = PaletteText.label(Typography.caption, tone: index == titles.count - 1 ? .primary : .secondary)
            label.stringValue = index == 0 ? title : "\u{203A} " + title
            button.addSubview(label)
            button.onClick = { [weak self] in self?.onCrumb?(index) }
            button.setAccessibilityRole(.button)
            button.setAccessibilityLabel(title)
            addSubview(button)
            return (button, label)
        }
    }

    /// The segments left to right from `x`; leading ones hide when the
    /// path is wider than `right` (the folder shown stays visible).
    private func layoutCrumbs(from x: CGFloat, to right: CGFloat) {
        let widths = crumbs.map { PaletteText.fittingWidth($0.label) + Metrics.space2 }
        var first = 0
        while first < crumbs.count - 1, widths[first...].reduce(0, +) > right - x { first += 1 }
        var left = x
        for (index, crumb) in crumbs.enumerated() {
            crumb.button.isHidden = index < first
            guard index >= first else { continue }
            let height = crumb.label.intrinsicContentSize.height
            crumb.button.frame = NSRect(x: left, y: bounds.midY - height / 2, width: widths[index], height: height)
            crumb.label.frame = NSRect(x: 0, y: 0, width: widths[index], height: height)
            left += widths[index]
        }
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

import AppKit
import CmuxAgentBrands
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
            let radius = Metrics.buttonCornerRadius(fitting: bounds.size)
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
    /// The preview look's pill behind the primary action and Actions (`experiments.palettePreview`).
    private let pill = NSView()
    private var showsPill = false
    /// How far the pill ends from the footer's right edge: the Actions menu anchors its right edge there.
    static var pillTrailing: CGFloat { PaletteLayout.listInset }

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
        pill.wantsLayer = true
        pill.isHidden = true
        addSubview(pill)
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
                crumbs titles: [String] = [], pill showsPill: Bool = false) {
        if titles != crumbs.map(\.label.stringValue) { setCrumbs(titles) }
        if showsPill != self.showsPill {
            // The preview look: the primary action and "Actions ⌘ K" in one pill; otherwise today's "Actions ⇥".
            self.showsPill = showsPill
            actionsKeys.keycaps = showsPill ? ["⌘", "K"] : ["⇥"]
            pill.isHidden = !showsPill
        }
        pageLabel.isHidden = !titles.isEmpty
        closeLabel.stringValue = closeTitle ?? ""
        closeButton.isHidden = closeTitle == nil
        pageIcon.image = pageSymbol.isEmpty ? nil : PaletteText.symbol(pageSymbol, size: Metrics.smallIconSize)
        pageIcon.isHidden = pageSymbol.isEmpty
        pageLabel.stringValue = pageTitle
        primaryLabel.stringValue = primaryTitle ?? ""
        primaryLabel.lineBreakMode = .byTruncatingMiddle
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
            if showsPill {
                pill.layer?.backgroundColor = Palette.hoverFill.cgColor
                pill.layer?.borderColor = Palette.separator.cgColor
                pill.layer?.borderWidth = Metrics.dividerThickness
            }
        }
        let padding = PaletteLayout.horizontalPadding
        let midY = bounds.midY
        let iconBox = Metrics.smallIconSize + Metrics.space1 * 2
        pageIcon.frame = NSRect(x: padding, y: midY - iconBox / 2, width: iconBox, height: iconBox)
        // The pill holds the primary action and Actions with its own inset; it ends near the panel's edge.
        let pillInset = Metrics.space3
        let pillRight = bounds.maxX - Self.pillTrailing
        var right = showsPill ? pillRight - pillInset : bounds.maxX - padding
        right = layoutButton(actionsButton, label: actionsLabel, keys: actionsKeys, right: right)
        if !primaryButton.isHidden {
            right -= Metrics.space4
            let dividerHeight = Metrics.iconSize
            divider.frame = NSRect(x: right - Metrics.dividerThickness, y: midY - dividerHeight / 2,
                                   width: Metrics.dividerThickness, height: dividerHeight)
            right -= Metrics.dividerThickness + Metrics.space4
            right = layoutButton(primaryButton, label: primaryLabel, keys: primaryKeys, right: right)
        }
        if showsPill {
            right -= pillInset
            let pillHeight = max(0, bounds.height - Metrics.space2 * 2)
            let size = NSSize(width: pillRight - right, height: pillHeight)
            pill.frame = pixelAligned(NSRect(x: right, y: midY - pillHeight / 2, width: size.width, height: size.height))
            pill.layer?.cornerRadius = Metrics.buttonCornerRadius(fitting: size)
        }
        if !closeButton.isHidden {
            right -= Metrics.space5
            right = layoutButton(closeButton, label: closeLabel, keys: closeKeys, right: right)
        }
        let labelX = pageIcon.isHidden ? padding : pageIcon.frame.maxX + Metrics.space3
        let height = PaletteText.height(pageLabel)
        pageLabel.frame = pixelAligned(NSRect(x: labelX, y: PaletteText.capCenteredY(pageLabel, height: height, midY: midY),
                                              width: max(0, right - Metrics.space4 - labelX), height: height))
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
            let height = PaletteText.height(crumb.label)
            let y = PaletteText.capCenteredY(crumb.label, height: height, midY: bounds.midY)
            crumb.button.frame = pixelAligned(NSRect(x: left, y: y, width: widths[index], height: height))
            crumb.label.frame = crumb.button.bounds
            left += widths[index]
        }
    }

    /// A label and its keycaps, right-aligned at `right`: the label's capitals and the keycaps centered on the
    /// footer's middle, so "Search", "Run Command ↩" and "Actions ⇥" share one center line at every text size
    /// (#48512). The button is the union of the two, so neither draws outside it.
    private func layoutButton(_ button: NSView, label: NSTextField, keys: PaletteKeycapsView, right: CGFloat) -> CGFloat {
        let midY = bounds.midY
        // A Return label naming a long row truncates rather than pushing the page title out.
        let labelSize = NSSize(width: min(PaletteText.fittingWidth(label), bounds.width * 0.5), height: PaletteText.height(label))
        let keySize = keys.intrinsicContentSize
        let width = labelSize.width + Metrics.space3 + keySize.width
        let labelY = PaletteText.capCenteredY(label, height: labelSize.height, midY: midY)
        let keysY = midY - keySize.height / 2
        let minY = min(labelY, keysY)
        let maxY = max(labelY + labelSize.height, keysY + keySize.height)
        button.frame = backingAlignedRect(NSRect(x: right - width, y: minY, width: width, height: maxY - minY),
                                          options: [.alignMinXNearest, .alignWidthNearest, .alignMinYOutward, .alignMaxYOutward])
        let bottom = button.frame.minY
        label.frame = button.pixelAligned(NSRect(x: 0, y: labelY - bottom, width: labelSize.width, height: labelSize.height))
        keys.frame = button.pixelAligned(NSRect(x: labelSize.width + Metrics.space3, y: keysY - bottom,
                                                width: keySize.width, height: keySize.height))
        return button.frame.minX
    }
}

/// The preview pane right of the list (`experiments.palettePreview`): the highlighted row's icon and title, then an
/// "Information" list of its facts (``PaletteFacts``), label left in the secondary tone, value right, every other line
/// on a faint fill. The facts are read for the row shown only, when it changes or the results reload.
final class PalettePreviewPaneView: NSView {
    private let hairline = NSView()
    private let icon = NSImageView()
    private let titleLabel = PaletteText.label(Typography.bodyEmphasized)
    private let heading = PaletteText.label(Typography.caption, tone: .secondary)
    /// Reused lines, grown to the most facts shown; lines past the shown facts hide.
    private var lines: [(fill: NSView, label: PaletteLabel, value: PaletteLabel)] = []
    private var shownCount = 0
    private var shownID: String?
    private var shownVersion = -1

    nonisolated override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        hairline.wantsLayer = true
        icon.imageScaling = .scaleProportionallyDown
        heading.stringValue = PaletteStrings.previewInformation
        [hairline, icon, titleLabel, heading].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows `item` (nil: an empty pane). `version` is the results version: the same row in reloaded results reads
    /// its facts again (a renamed workspace), the same row in the same results reads nothing.
    func show(_ item: PaletteItem?, version: Int) {
        guard item?.id != shownID || version != shownVersion else { return }
        shownID = item?.id
        shownVersion = version
        titleLabel.stringValue = item?.title ?? ""
        icon.image = item.flatMap { item in
            item.brand.flatMap { AgentBrandCatalog.templateImage(brand: $0, size: Metrics.iconSize) }
                ?? PaletteText.symbol(item.symbol ?? "command", size: Metrics.iconSize)
        }
        let facts = item.map(PaletteFacts.of) ?? []
        while lines.count < facts.count {
            let line = (fill: NSView(), label: PaletteText.label(Typography.body, tone: .secondary), value: PaletteText.label(Typography.body))
            line.fill.wantsLayer = true
            line.value.alignment = .right
            line.value.lineBreakMode = .byTruncatingMiddle
            [line.fill, line.label, line.value].forEach(addSubview)
            lines.append(line)
        }
        for (index, line) in lines.enumerated() {
            let shown = index < facts.count
            line.label.stringValue = shown ? facts[index].label : ""
            line.value.stringValue = shown ? facts[index].value : ""
            line.value.toolTip = shown ? facts[index].value : nil
        }
        shownCount = facts.count
        heading.isHidden = facts.isEmpty
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        performWithTheme {
            hairline.layer?.backgroundColor = Palette.separator.cgColor
            icon.contentTintColor = Palette.textSecondary
            for (index, line) in lines.enumerated() {
                line.fill.layer?.backgroundColor = index.isMultiple(of: 2) ? Palette.hoverFill.cgColor : NSColor.clear.cgColor
            }
        }
        hairline.frame = NSRect(x: 0, y: 0, width: Metrics.dividerThickness, height: bounds.height)
        let inset = PaletteLayout.listInset + Metrics.space2
        let left = Metrics.dividerThickness + inset, width = max(0, bounds.width - left - inset)
        let rowHeight = PaletteLayout.rowHeight
        // The selection's icon and title on top, as its row draws them.
        var y = PaletteLayout.listInset
        let iconBox = PaletteLayout.iconBox
        icon.frame = NSRect(x: left + Metrics.space2, y: y + (rowHeight - iconBox) / 2, width: iconBox, height: iconBox)
        let titleX = icon.frame.maxX + Metrics.space3
        let titleHeight = PaletteText.height(titleLabel)
        titleLabel.frame = pixelAligned(NSRect(x: titleX, y: y + (rowHeight - titleHeight) / 2,
                                               width: max(0, left + width - Metrics.space2 - titleX), height: titleHeight))
        y += rowHeight + Metrics.space3
        let headingHeight = PaletteText.height(heading)
        heading.frame = pixelAligned(NSRect(x: left + Metrics.space2, y: y, width: max(0, width - Metrics.space2 * 2), height: headingHeight))
        y += headingHeight + Metrics.space2
        let lineHeight = PaletteLayout.actionsMenuRowHeight
        for (index, line) in lines.enumerated() {
            let shown = index < shownCount
            line.fill.isHidden = !shown
            line.label.isHidden = !shown
            line.value.isHidden = !shown
            guard shown else { continue }
            let frame = NSRect(x: left, y: y, width: width, height: lineHeight)
            line.fill.frame = frame
            line.fill.layer?.cornerRadius = PaletteLayout.keycapCornerRadius
            let textHeight = PaletteText.height(line.label)
            let textY = y + (lineHeight - textHeight) / 2
            let labelWidth = min(PaletteText.fittingWidth(line.label), width * 0.45)
            line.label.frame = pixelAligned(NSRect(x: left + Metrics.space2, y: textY, width: labelWidth, height: textHeight))
            let valueX = line.label.frame.maxX + Metrics.space3
            line.value.frame = pixelAligned(NSRect(x: valueX, y: textY, width: max(0, left + width - Metrics.space2 - valueX), height: textHeight))
            y += lineHeight
        }
    }
}

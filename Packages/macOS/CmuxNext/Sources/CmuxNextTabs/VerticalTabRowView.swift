import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// One row of ``VerticalTabListView``: the tab's icon and title, the selection fill, and a close
/// button while the pointer is over it. Clicks go out through the list's closures; the row never
/// edits the model.
final class VerticalTabRowView: NSView {
    private(set) var item: TabItem
    private(set) var isSelected = false
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var tracking: NSTrackingArea?
    private var isHovered = false { didSet { if isHovered != oldValue { refresh() } } }
    /// A plain click on the row.
    var onActivate: (() -> Void)?
    /// The close button or a middle click.
    var onClose: ((TabCloseSource) -> Void)?

    init(item: TabItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Metrics.space2
        iconView.imageScaling = .scaleProportionallyDown
        titleField.lineBreakMode = .byTruncatingTail
        titleField.font = Typography.body
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: Strings.axClose)
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = Strings.axClose
        [iconView, titleField, closeButton].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        update(item, selected: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var isFlipped: Bool { true }

    func update(_ item: TabItem, selected: Bool) {
        self.item = item
        isSelected = selected
        titleField.stringValue = item.title.isEmpty ? Strings.untitled : item.title
        setAccessibilityLabel(titleField.stringValue)
        setAccessibilityValue(selected)
        refresh()
    }

    /// Colors and icon from the row's theme scope; the close button only on hover, never on a tab
    /// that cannot close.
    private func refresh() {
        performWithTheme {
            let text = isSelected ? Palette.textPrimary : Palette.textSecondary
            titleField.textColor = item.isDormant ? text.withAlphaComponent(0.5) : text
            closeButton.contentTintColor = Palette.textSecondary
            let fill: NSColor? = isSelected ? Palette.selectionFill : (isHovered && DesignSettings.shared.showsHoverFills ? Palette.hoverFill : nil)
            layer?.backgroundColor = fill?.cgColor
            iconView.image = icon(tint: text).map { NSImage(cgImage: $0, size: NSSize(width: Metrics.iconSize, height: Metrics.iconSize)) }
        }
        closeButton.isHidden = !(isHovered && item.isClosable && !item.isPinned)
        needsLayout = true
    }

    private func icon(tint: NSColor) -> CGImage? {
        let size = Metrics.iconSize, scale = window?.backingScaleFactor ?? 2
        switch item.icon {
        case .none:
            return item.isPinned ? TabSymbolCache.shared.image(named: "pin.fill", tint: tint, pointSize: Metrics.smallIconSize, size: size, scale: scale) : nil
        case .image(let image): return image.cgImage
        case .agentMark(let brand):
            return TabAgentMarkCache.shared.image(brand: brand, tint: tint, size: size, scale: scale)
                ?? TabPackIconCache.shared.image(name: .terminal, tint: tint, size: size, scale: scale)
        case .icon(let name):
            return TabPackIconCache.shared.image(name: name, tint: tint, size: size, scale: scale)
                ?? TabSymbolCache.shared.image(named: IconCatalog.bundled.entry(for: name)?.sf ?? "questionmark.square.dashed",
                                               tint: tint, pointSize: size, size: size, scale: scale)
        case .symbol(let name):
            return TabSymbolCache.shared.image(named: name, tint: tint, pointSize: Metrics.smallIconSize, size: size, scale: scale)
        }
    }

    override func layout() {
        super.layout()
        let inset = Metrics.space2, icon = Metrics.iconSize, close = bounds.height - 2 * Metrics.space1
        iconView.frame = NSRect(x: inset, y: (bounds.height - icon) / 2, width: icon, height: icon)
        closeButton.frame = NSRect(x: bounds.width - inset - close, y: Metrics.space1, width: close, height: close)
        let titleX = iconView.frame.maxX + inset, titleRight = closeButton.isHidden ? bounds.width - inset : closeButton.frame.minX - Metrics.space1
        let titleHeight = titleField.intrinsicContentSize.height
        titleField.frame = NSRect(x: titleX, y: (bounds.height - titleHeight) / 2, width: max(0, titleRight - titleX), height: titleHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    override func mouseDown(with event: NSEvent) { onActivate?() }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, item.isClosable, !item.isPinned else { return super.otherMouseDown(with: event) }
        onClose?(.middleClick)
    }

    override func accessibilityPerformPress() -> Bool {
        onActivate?()
        return true
    }

    @objc private func closeClicked() { onClose?(.mouse) }
}

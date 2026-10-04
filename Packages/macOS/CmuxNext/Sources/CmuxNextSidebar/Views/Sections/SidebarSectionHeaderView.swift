import AppKit
import CmuxNextDesign

/// The title row of a titled pinned section. A click collapses or expands
/// it; the chevron shows on hover and while collapsed.
final class SidebarSectionHeaderView: NSView {
    var onPress: (() -> Void)?
    var onContextMenu: ((NSEvent, NSView) -> Void)?

    private let name = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var collapsed = false
    private var isHovered = false { didSet { if isHovered != oldValue { updateChevron() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.lineBreakMode = .byTruncatingTail
        name.maximumNumberOfLines = 1
        [name, chevron].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(title: String, collapsed: Bool) {
        name.stringValue = title
        self.collapsed = collapsed
        setAccessibilityLabel(title)
        setAccessibilityExpanded(!collapsed)
        setAccessibilityHelp(collapsed ? SectionStrings.expand : SectionStrings.collapse)
        updateChevron()
        needsLayout = true
    }

    private func updateChevron() {
        chevron.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(SidebarStyle.chevronConfig)
        chevron.isHidden = !(collapsed || isHovered)
    }

    override func updateLayer() {
        performWithTheme {
            name.textColor = Palette.textTertiary
            chevron.contentTintColor = Palette.textTertiary
        }
    }

    override func layout() {
        super.layout()
        let b = bounds
        let inset = SidebarStyle.horizontalInset * 2
        name.font = SidebarStyle.headerFont
        let th = ceil(name.intrinsicContentSize.height)
        let chevronSide = Metrics.smallIconSize
        chevron.frame = NSRect(x: b.width - inset - chevronSide, y: (b.height - chevronSide) / 2, width: chevronSide, height: chevronSide)
        name.frame = NSRect(x: inset, y: (b.height - th) / 2, width: max(0, chevron.frame.minX - Metrics.space2 - inset), height: th)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { onPress?() }

    override func rightMouseDown(with event: NSEvent) {
        guard let onContextMenu else { return super.rightMouseDown(with: event) }
        onContextMenu(event, self)
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

import AppKit
import CmuxNextDesign
import QuartzCore

/// The pinned Home row above the workspace list: it never scrolls, and a
/// hairline under it marks where the list scrolls beneath. Home shows the
/// mux Messages screen in place of a workspace.
final class HomeRowView: NSView {
    var onPress: (() -> Void)?
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            setAccessibilitySelected(isActive)
            needsDisplay = true
        }
    }

    private let pill = CALayer()
    private let separator = CALayer()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: Strings.home)
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }

    /// Row plus its padding and the hairline.
    static var preferredHeight: CGFloat { Metrics.sidebarRowHeight + Metrics.space2 * 2 + separatorWidth }
    private static var separatorWidth: CGFloat { 1 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for decoration in [pill, separator] {
            decoration.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(decoration)
        }
        pill.cornerCurve = .continuous
        icon.imageScaling = .scaleProportionallyDown
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        addSubview(icon)
        addSubview(title)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(Strings.home)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateLayer() {
        performWithTheme {
            pill.backgroundColor = isActive ? Palette.selectionFill.cgColor : isHovered ? Palette.hoverFill.cgColor : nil
            separator.backgroundColor = Palette.separator.cgColor
            title.textColor = Palette.textPrimary
            icon.contentTintColor = isActive ? Palette.textPrimary : Palette.textSecondary
        }
    }

    override func layout() {
        super.layout()
        let b = bounds
        let inset = SidebarStyle.horizontalInset
        let rowHeight = Metrics.sidebarRowHeight
        let rowY = Metrics.space2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.frame = NSRect(x: inset, y: rowY, width: max(0, b.width - inset * 2), height: rowHeight)
        pill.cornerRadius = SidebarStyle.rowCornerRadius
        separator.frame = NSRect(x: 0, y: b.height - Self.separatorWidth, width: b.width, height: Self.separatorWidth)
        CATransaction.commit()

        icon.image = NSImage(systemSymbolName: "house", accessibilityDescription: nil)?
            .withSymbolConfiguration(SidebarStyle.glyphConfig)
        let side = SidebarStyle.iconBox
        // The glyph lines up with the text of rows below (their inset plus the pill inset).
        let leading = inset * 2
        icon.frame = NSRect(x: leading, y: rowY + (rowHeight - side) / 2, width: side, height: side)
        title.font = SidebarStyle.titleFont
        let th = ceil(title.intrinsicContentSize.height)
        let textX = icon.frame.maxX + Metrics.space3
        title.frame = NSRect(x: textX, y: rowY + (rowHeight - th) / 2, width: max(0, b.width - textX - inset * 2), height: th)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard pill.frame.contains(point) else { return super.mouseDown(with: event) }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

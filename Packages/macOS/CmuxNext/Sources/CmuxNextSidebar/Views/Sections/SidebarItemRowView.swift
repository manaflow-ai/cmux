import AppKit
import CmuxNextDesign
import QuartzCore

/// One item of a sticky section: a row (built-in or list look) or a tray
/// tile. A pill shows on hover and while the item is active.
final class SidebarItemRowView: NSView {
    enum Style: Hashable {
        /// Bare glyph and label: reads as app chrome (Home).
        case builtIn
        /// Glyph in a rounded chip: reads like a workspace row.
        case list
        /// Glyph only, centered, on a faint tile (tray look).
        case tile
        /// Glyph only, centered, no fill at rest (inline icons).
        case icon
        /// Glyph and label side by side on one line (inline), no fill at rest.
        case chip

        var isIconOnly: Bool { self == .tile || self == .icon }
    }

    var onPress: (() -> Void)?
    var onContextMenu: ((NSEvent, NSView) -> Void)?

    private(set) var info = SidebarItemInfo(title: "", symbol: "circle")
    private(set) var style = Style.builtIn
    private let pill = CALayer()
    private let chip = CALayer()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let badge = UnreadBadgeView()
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for decoration in [pill, chip] {
            decoration.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
            decoration.cornerCurve = .continuous
            layer?.addSublayer(decoration)
        }
        icon.imageScaling = .scaleProportionallyDown
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        [icon, title, badge].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Width of a chip showing `title`: padding, glyph, gap, label, padding.
    static func chipWidth(title: String, font: NSFont, badge: Int? = nil) -> CGFloat {
        // The label's own width (a text field adds its cell padding).
        let label = NSTextField(labelWithString: title)
        label.font = font
        let text = ceil(label.intrinsicContentSize.width)
        // One extra space2 of slack: measured and drawn widths differ by a
        // few points between window contexts (seen in offscreen renders).
        return Metrics.space2 + SidebarStyle.iconBox + Metrics.space2 + text + Metrics.space2 * 2
    }

    /// The unread badge draws (tests).
    var isBadgeShown: Bool { !badge.isHidden }

    func configure(_ info: SidebarItemInfo, style: Style) {
        guard info != self.info || style != self.style else { return }
        self.info = info
        self.style = style
        title.stringValue = info.title
        title.isHidden = style.isIconOnly
        badge.configure(info.badge.map(UnreadState.count) ?? .none)
        if style.isIconOnly || style == .chip { badge.isHidden = true }
        toolTip = style.isIconOnly ? info.title : nil
        setAccessibilityLabel(info.title)
        setAccessibilitySelected(info.isActive)
        alphaValue = info.isMissing ? 0.5 : 1
        needsLayout = true
        needsDisplay = true
    }

    override func updateLayer() {
        performWithTheme {
            let rest: NSColor? = style == .tile ? Palette.hoverFill : nil
            pill.backgroundColor = (info.isActive ? Palette.selectionFill : isHovered ? Palette.hoverFill : rest)?.cgColor
            chip.backgroundColor = style == .list ? (info.color.map(SidebarStyle.color) ?? Palette.hoverFill).cgColor : nil
            title.textColor = Palette.textPrimary
            icon.contentTintColor = style == .list && info.color != nil ? Palette.textOnPrimary
                : info.isActive ? Palette.textPrimary : Palette.textSecondary
        }
    }

    override func layout() {
        super.layout()
        let b = bounds
        let inset = SidebarStyle.horizontalInset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let pillFrame = style.isIconOnly || style == .chip ? b : NSRect(x: inset, y: 0, width: max(0, b.width - inset * 2), height: b.height)
        pill.frame = pillFrame
        pill.cornerRadius = SidebarStyle.rowCornerRadius
        let side = SidebarStyle.iconBox
        // The glyph lines up with the text of workspace rows (their inset plus the pill inset).
        let iconFrame = style.isIconOnly
            ? NSRect(x: (b.width - side) / 2, y: (b.height - side) / 2, width: side, height: side)
            : NSRect(x: style == .chip ? Metrics.space2 : inset * 2, y: (b.height - side) / 2, width: side, height: side)
        chip.frame = style == .list ? iconFrame : .zero
        chip.cornerRadius = Metrics.space1 + 1
        CATransaction.commit()

        let pointSize = style == .list ? Metrics.smallIconSize - Metrics.space2 : Metrics.smallIconSize - Metrics.space1
        icon.image = NSImage(systemSymbolName: info.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
        let glyph = style == .list ? iconFrame.insetBy(dx: 2, dy: 2) : iconFrame
        icon.frame = glyph
        title.font = SidebarStyle.titleFont
        let bh = SidebarStyle.badgeHeight
        let badgeWidth = badge.isHidden ? 0 : badge.preferredWidth
        let badgeX = style == .chip ? b.width : b.width - inset * 2 - badgeWidth
        badge.frame = NSRect(x: badgeX, y: (b.height - bh) / 2, width: badgeWidth, height: bh)
        let th = ceil(title.intrinsicContentSize.height)
        let textX = iconFrame.maxX + (style == .chip ? Metrics.space2 : Metrics.space3)
        title.frame = NSRect(x: textX, y: (b.height - th) / 2, width: max(0, badgeX - Metrics.space2 - textX), height: th)
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
        guard pill.frame.contains(convert(event.locationInWindow, from: nil)) else { return super.mouseDown(with: event) }
        onPress?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let onContextMenu else { return super.rightMouseDown(with: event) }
        onContextMenu(event, self)
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

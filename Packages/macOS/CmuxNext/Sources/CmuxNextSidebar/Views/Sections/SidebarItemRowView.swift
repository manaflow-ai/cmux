import AppKit
import CmuxNextDesign
import QuartzCore

/// One item of a pinned section: a row (built-in or list look) or a tray
/// tile. A pill shows on hover, while pressed and while the item is
/// active, in the shared chrome fills (`ChromeHover.fillColor`), fading on
/// pointer changes. The rail's icon-only items show unread items as a dot
/// on the glyph instead of a count; the sidebar's own icon looks hide them.
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

    /// A window rail button: a larger, brighter glyph on a rounder tile,
    /// and unread items as a dot on the glyph (the Codex rail).
    var isRailButton = false
    var onPress: (() -> Void)?
    /// The trailing control was pressed (`SidebarItemInfo.accessory`).
    var onAccessory: (() -> Void)?
    /// The accessory draws (tests).
    var isAccessoryShown: Bool { !accessoryView.isHidden }
    /// The accessory's frame while it draws (tests).
    var accessoryFrame: CGRect? { accessoryView.isHidden ? nil : accessoryView.frame }
    /// The trailing control (`SidebarItemInfo.accessory`): the update badge.
    private let accessoryView = NSImageView()
    /// Modifier-aware activation for controls whose action has a one-shot
    /// Option override. Plain activations continue through `onPress`.
    var onPressWithModifiers: ((NSEvent.ModifierFlags) -> Void)?
    var onContextMenu: ((NSEvent, NSView) -> Void)?

    private(set) var info = SidebarItemInfo(title: "", symbol: "circle")
    private(set) var style = Style.builtIn
    private let pill = CALayer()
    private let chip = CALayer()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let badge = UnreadBadgeView()
    private var isHovered = false { didSet { if isHovered != oldValue { pointerChanged() } } }
    private var isPressed = false { didSet { if isPressed != oldValue { pointerChanged() } } }
    /// The next fill change came from the pointer, so it fades.
    private var fadesNextFill = false

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
        accessoryView.imageScaling = .scaleProportionallyDown
        accessoryView.isHidden = true
        [icon, title, badge, accessoryView].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Width of a chip showing `title` (and an unread count): padding,
    /// glyph, gap, label, badge, padding. Cached per title and font size,
    /// because inline sections measure every item on every layout pass.
    static func chipWidth(title: String, font: NSFont, badge: Int? = nil) -> CGFloat {
        let key = ChipKey(title: title, pointSize: font.pointSize, badge: badge.map { min($0, 100) })
        if let cached = chipWidths[key] { return cached }
        // The label's own width (a text field adds its cell padding), plus
        // one space2 of slack: measured and drawn widths differ by a few
        // points between window contexts (seen in offscreen renders).
        let label = NSTextField(labelWithString: title)
        label.font = font
        var width = Metrics.space2 + SidebarStyle.iconBox + Metrics.space2 + ceil(label.intrinsicContentSize.width) + Metrics.space2 * 2
        if let badge, badge > 0 { width += UnreadBadgeView.width(count: badge) + Metrics.space2 }
        if chipWidths.count > 512 { chipWidths.removeAll() }
        chipWidths[key] = width
        return width
    }

    private struct ChipKey: Hashable {
        var title: String
        var pointSize: CGFloat
        var badge: Int?
    }

    private static var chipWidths: [ChipKey: CGFloat] = [:]

    /// The unread badge draws (tests).
    var isBadgeShown: Bool { !badge.isHidden }
    /// The glyph's frame (tests).
    var glyphFrame: CGRect { icon.frame }
    /// The badge's frame while it draws (tests).
    var badgeFrame: CGRect? { badge.isHidden ? nil : badge.frame }

    func configure(_ info: SidebarItemInfo, style: Style) {
        guard info != self.info || style != self.style else { return }
        self.info = info
        self.style = style
        title.stringValue = info.title
        title.isHidden = style.isIconOnly
        // Icons have no room for a count: unread items show a dot at the
        // glyph's top trailing corner (the rail, like the Codex app's).
        let unread: UnreadState
        if style.isIconOnly {
            unread = isRailButton && (info.badge ?? 0) > 0 ? UnreadState.dot : UnreadState.none
        } else {
            unread = info.badge.map(UnreadState.count) ?? UnreadState.none
        }
        badge.configure(unread)
        configureAccessory(info.accessory)
        // VoiceOver hears the count even where no badge draws (icons).
        setAccessibilityValue(info.badge.map { String($0) })
        toolTip = style.isIconOnly ? info.title : nil
        setAccessibilityLabel(info.title)
        setAccessibilitySelected(info.isActive)
        alphaValue = info.isMissing ? 0.5 : 1
        needsLayout = true
        needsDisplay = true
    }

    override func updateLayer() {
        performWithTheme {
            ChromeHover.paint(pill, fill, animated: fadesNextFill)
            fadesNextFill = false
            chip.backgroundColor = style == .list ? (info.color.map(SidebarStyle.color) ?? Palette.hoverFill).cgColor : nil
            title.textColor = Palette.textPrimary
            icon.contentTintColor = style == .list && info.color != nil ? Palette.textOnPrimary
                : info.isActive || isRailButton ? Palette.textPrimary : Palette.textSecondary
        }
    }

    /// The pill's fill: pressed, then active, then hovered, then the
    /// tile's resting fill.
    var fill: NSColor? {
        let state = ChromeHover.State(hovering: isHovered, pressed: isPressed, selected: info.isActive)
        return performWithTheme { ChromeHover.fillColor(state, rest: style == .tile ? Palette.hoverFill : nil) }
    }

    private func pointerChanged() {
        fadesNextFill = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let b = bounds
        let inset = SidebarStyle.horizontalInset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let pillFrame = style.isIconOnly || style == .chip ? b : NSRect(x: inset, y: 0, width: max(0, b.width - inset * 2), height: b.height)
        pill.frame = pillFrame
        pill.cornerRadius = isRailButton ? SidebarStyle.railTileCornerRadius : SidebarStyle.rowCornerRadius
        let side = isRailButton ? SidebarStyle.railIconBox : SidebarStyle.iconBox
        // The glyph lines up with the text of workspace rows (their inset plus the pill inset).
        let iconFrame = style.isIconOnly
            ? NSRect(x: (b.width - side) / 2, y: (b.height - side) / 2, width: side, height: side)
            : NSRect(x: style == .chip ? Metrics.space2 : inset * 2, y: (b.height - side) / 2, width: side, height: side)
        chip.frame = style == .list ? iconFrame : .zero
        chip.cornerRadius = Metrics.space1 + 1
        CATransaction.commit()

        let pointSize = isRailButton ? SidebarStyle.railGlyphSize
            : style == .list ? Metrics.smallIconSize - Metrics.space2 : Metrics.smallIconSize - Metrics.space1
        icon.image = NSImage(systemSymbolName: info.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: isRailButton ? .medium : .regular))
        let glyph = style == .list ? iconFrame.insetBy(dx: 2, dy: 2) : iconFrame
        icon.frame = glyph
        title.font = SidebarStyle.titleFont
        if style.isIconOnly {
            let dot = SidebarStyle.dotSize
            badge.frame = NSRect(x: iconFrame.maxX - dot / 2, y: iconFrame.minY - dot / 2, width: dot, height: dot)
            title.frame = .zero
            return
        }
        // The accessory sits at the trailing edge, before any count badge.
        let accessorySide = Metrics.smallIconSize
        let accessoryX = b.width - Metrics.space2 - accessorySide
        accessoryView.frame = accessoryView.isHidden ? .zero
            : NSRect(x: accessoryX, y: (b.height - accessorySide) / 2, width: accessorySide, height: accessorySide)
        let trailing = accessoryView.isHidden ? b.width : accessoryX - Metrics.space1
        let bh = SidebarStyle.badgeHeight
        let badgeWidth = badge.isHidden ? 0 : badge.preferredWidth
        let badgeX = style == .chip
            ? (badge.isHidden ? trailing : trailing - Metrics.space2 - badgeWidth)
            : (accessoryView.isHidden ? b.width - inset * 2 : trailing) - badgeWidth
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
    override func mouseExited(with event: NSEvent) { isHovered = false; isPressed = false }

    /// Activates on press, as the sidebar's rows do; the pressed fill shows
    /// until release.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard pill.frame.contains(point) else { return super.mouseDown(with: event) }
        if hitsAccessory(point) { return onAccessory?() ?? () }
        isPressed = true
        if let onPressWithModifiers { onPressWithModifiers(event.modifierFlags) } else { onPress?() }
    }

    /// The accessory takes a click a little outside its glyph.
    private func hitsAccessory(_ point: NSPoint) -> Bool {
        !accessoryView.isHidden && accessoryView.frame.insetBy(dx: -Metrics.space1, dy: -Metrics.space1).contains(point)
    }

    private func configureAccessory(_ accessory: SidebarItemAccessory?) {
        guard let accessory else {
            accessoryView.isHidden = true
            setAccessibilityCustomActions(nil)
            return
        }
        switch accessory {
        case .update:
            accessoryView.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: Strings.updateAvailable)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Metrics.smallIconSize - Metrics.space1, weight: .semibold))
            accessoryView.contentTintColor = performWithTheme { Palette.accent }
            accessoryView.toolTip = Strings.updateAvailable
            accessoryView.isHidden = false
            setAccessibilityCustomActions([NSAccessibilityCustomAction(name: Strings.updateAvailable) { [weak self] in
                self?.onAccessory?()
                return true
            }])
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return super.mouseUp(with: event) }
        isPressed = false
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let onContextMenu else { return super.rightMouseDown(with: event) }
        onContextMenu(event, self)
    }

    /// A press at `point` (this view's coordinates), as a click there (tests).
    func press(at point: NSPoint) {
        if hitsAccessory(point) { return onAccessory?() ?? () }
        if let onPressWithModifiers { onPressWithModifiers([]) } else { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        if let onPressWithModifiers { onPressWithModifiers([]) } else { onPress?() }
        return true
    }
}

import AppKit
import CmuxNextDesign
import CmuxNextIcons
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
        /// A large glyph in a rounded well over a short centered label
        /// (the tiles arrangement), no fill at rest.
        case favorite

        var isIconOnly: Bool { self == .tile || self == .icon }
    }

    /// A window rail button: a larger, brighter glyph on a rounder tile,
    /// and unread items as a dot on the glyph (the Codex rail).
    var isRailButton = false
    var onPress: (() -> Void)?
    /// The glyph's tint (tests): secondary at rest, primary on hover.
    var glyphTint: NSColor? { icon.contentTintColor }
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
        [icon, title, badge].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    /// A drag from a press (window points): true once the region drags.
    var onDragged: ((NSPoint, NSEvent) -> Bool)?
    var onDragEnded: (() -> Void)?
    private var pressLocation: NSPoint?
    private var didDrag = false
    /// The press's modifiers, which the release acts with (Option opens a workspace).
    private var pressModifiers: NSEvent.ModifierFlags = []

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
        title.stringValue = style == .favorite ? info.caption ?? info.title : info.title
        title.isHidden = style.isIconOnly
        title.alignment = style == .favorite ? .center : .natural
        // Icons and tiles have no room for a count: unread items show a dot
        // at the glyph's top trailing corner (the rail, like the Codex app's).
        let unread: UnreadState
        if style == .favorite {
            unread = (info.badge ?? 0) > 0 ? UnreadState.dot : UnreadState.none
        } else if style.isIconOnly {
            unread = isRailButton && (info.badge ?? 0) > 0 ? UnreadState.dot : UnreadState.none
        } else {
            unread = info.badge.map(UnreadState.count) ?? UnreadState.none
        }
        badge.configure(unread)
        // VoiceOver hears the count even where no badge draws (icons).
        setAccessibilityValue(info.badge.map { String($0) })
        // An icon names itself (and its shortcut) in its tooltip; a tile's
        // caption can truncate, so it keeps the full title.
        toolTip = style.isIconOnly ? info.toolTip : style == .favorite ? info.title : nil
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
            let wells = style == .list || style == .favorite
            // A tile's well is the raised surface on the tiles card (Safari's
            // favorites); a list row's well is the quieter hover step.
            let rest = style == .favorite ? Palette.elevatedBackground : Palette.hoverFill
            chip.backgroundColor = wells ? (info.color.map(SidebarStyle.color) ?? rest).cgColor : nil
            title.textColor = Palette.textPrimary
            // An icon is secondary at rest and full strength under the pointer
            // or keyboard focus (the footer's avatar and gear).
            let strong = style == .icon && (isHovered || isPressed || isKeyFocused)
            icon.contentTintColor = wells && info.color != nil ? Palette.textOnPrimary
                : style == .favorite ? Palette.textPrimary
                : info.isActive || isRailButton || strong ? Palette.textPrimary : Palette.textSecondary
        }
    }

    /// Where the sidebar's selection highlight sits under this item.
    var selectionRect: CGRect { pill.frame }
    /// Tiles keep their own selected fill (the shared highlight would sit under the tile card).
    var drawsOwnSelection: Bool { style == .tile || style == .favorite }

    /// The pill's fill: pressed, then active, then hovered, then the
    /// tile's resting fill. A tile rests on `hoverFill`, so its hover takes
    /// the next tonal step (`selectionFill`) and still shows a change (R97).
    var fill: NSColor? {
        // A selected list or rail item: the sidebar's one highlight draws under it.
        let state = ChromeHover.State(hovering: isHovered, pressed: isPressed, selected: info.isActive && drawsOwnSelection)
        return performWithTheme {
            guard style == .tile else { return ChromeHover.fillColor(state) }
            if state.hovering, !state.pressed, !state.selected { return Palette.selectionFill }
            return ChromeHover.fillColor(state, rest: Palette.hoverFill)
        }
    }

    private func pointerChanged() {
        fadesNextFill = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let b = bounds
        if style == .favorite { return layoutFavorite(b) }
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

        // Row size beside a title, like a workspace row's type glyph; inside a list well, the well's
        // glyph size; a rail button's own glyph size.
        let glyphSide = isRailButton ? SidebarStyle.railGlyphSize : style == .list ? SidebarStyle.wellGlyphSize : SidebarStyle.kindGlyphSize
        icon.image = glyphImage(side: glyphSide)
        icon.frame = alignedGlyphFrame(side: glyphSide, centeredIn: iconFrame)
        title.font = SidebarStyle.titleFont
        if style.isIconOnly {
            let dot = SidebarStyle.dotSize
            badge.frame = NSRect(x: iconFrame.maxX - dot / 2, y: iconFrame.minY - dot / 2, width: dot, height: dot)
            title.frame = .zero
            return
        }
        let trailing = b.width
        let bh = SidebarStyle.badgeHeight
        let badgeWidth = badge.isHidden ? 0 : badge.preferredWidth
        let badgeX = style == .chip
            ? (badge.isHidden ? trailing : trailing - Metrics.space2 - badgeWidth)
            : b.width - inset * 2 - badgeWidth
        badge.frame = NSRect(x: badgeX, y: (b.height - bh) / 2, width: badgeWidth, height: bh)
        let th = ceil(title.intrinsicContentSize.height)
        let textX = iconFrame.maxX + (style == .chip ? Metrics.space2 : Metrics.space3)
        title.frame = NSRect(x: textX, y: (b.height - th) / 2, width: max(0, badgeX - Metrics.space2 - textX), height: th)
    }

    /// A large tile: the glyph well centered over a one-line caption, the
    /// pair centered in the tile. An unread item shows a dot on the well.
    private func layoutFavorite(_ b: NSRect) {
        title.font = SidebarStyle.subtitleFont
        let well = SidebarStyle.favoriteWell
        let th = ceil(title.intrinsicContentSize.height)
        let wellFrame = NSRect(x: (b.width - well) / 2, y: max(0, (b.height - well - Metrics.space1 - th) / 2),
                               width: well, height: well)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.frame = b
        pill.cornerRadius = SidebarStyle.railTileCornerRadius
        chip.frame = wellFrame
        chip.cornerRadius = SidebarStyle.railTileCornerRadius
        CATransaction.commit()
        icon.image = glyphImage(side: SidebarStyle.railGlyphSize)
        icon.frame = alignedGlyphFrame(side: SidebarStyle.railGlyphSize, centeredIn: wellFrame)
        // The caption takes the tile's full width: a tile is narrow, and the
        // tiles' gap already separates neighboring captions.
        title.frame = NSRect(x: 0, y: wellFrame.maxY + Metrics.space1, width: b.width, height: th)
        let dot = SidebarStyle.dotSize
        badge.frame = NSRect(x: wellFrame.maxX - dot / 2 - 1, y: wellFrame.minY - dot / 2 + 1, width: dot, height: dot)
    }

    /// The item's avatar, else its registry icon at `side` points; without
    /// one, its SF Symbol at the matching text size.
    private func glyphImage(side: CGFloat) -> NSImage? {
        if let avatar = info.avatar { return avatarImage(avatar, side: side) }
        if let name = info.icon { return NSImage.icon(name, size: side) }
        let symbol = NSImage(systemSymbolName: info.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: side * 0.8, weight: .regular))
        return symbol ?? NSImage.icon(.appGeneric, size: side)
    }

    /// A `side` circle in the theme's colors at the window's pixel scale.
    private func avatarImage(_ avatar: SidebarAvatar, side: CGFloat) -> NSImage {
        let (fill, ink) = performWithTheme { (Palette.textSecondary.cgColor, Palette.textOnPrimary.cgColor) }
        return avatar.image(side: side, scale: window?.backingScaleFactor ?? 2, fill: fill, ink: ink)
    }

    /// The item draws an avatar in place of its glyph (tests).
    var drawsAvatar: Bool { info.avatar != nil }

    /// A `side` square centered in `box`, on the device pixel grid so the icon's strokes stay crisp.
    private func alignedGlyphFrame(side: CGFloat, centeredIn box: NSRect) -> NSRect {
        let scale = window?.backingScaleFactor ?? 2
        let snap = { (value: CGFloat) in (value * scale).rounded() / scale }
        return NSRect(x: snap(box.midX - side / 2), y: snap(box.midY - side / 2), width: side, height: side)
    }

    /// The glyph drawn now (tests).
    var glyphImage: NSImage? { icon.image }
    /// The caption's frame (tests).
    var titleFrame: CGRect { title.isHidden ? .zero : title.frame }
    /// The drawn title or caption (tests).
    var titleText: String { title.stringValue }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        // An avatar's initials resolve the theme's colors when drawn.
        if info.avatar != nil { needsLayout = true }
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
        isPressed = true
        pressLocation = event.locationInWindow
        pressModifiers = event.modifierFlags
        didDrag = false
    }

    /// Past the drag threshold the region reorders in place (R77).
    override func mouseDragged(with event: NSEvent) {
        guard let pressLocation, onDragged?(pressLocation, event) == true else { return super.mouseDragged(with: event) }
        didDrag = true
        isPressed = false
    }

    /// The item acts on release, like a button: a press that became a drag
    /// (or left the item first) never opens it. Acting on the press opened
    /// the App Store, Import and Sync or a new workspace under a tile the
    /// user only meant to move.
    override func mouseUp(with event: NSEvent) {
        let dragged = didDrag
        if dragged { onDragEnded?() }
        pressLocation = nil
        didDrag = false
        guard isPressed else { return super.mouseUp(with: event) }
        isPressed = false
        guard !dragged, pill.frame.contains(convert(event.locationInWindow, from: nil)) else { return }
        if let onPressWithModifiers { onPressWithModifiers(pressModifiers) } else { onPress?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let onContextMenu else { return super.rightMouseDown(with: event) }
        onContextMenu(event, self)
    }

    /// A press at `point` (this view's coordinates), as a click there (tests).
    func press(at point: NSPoint) {
        if let onPressWithModifiers { onPressWithModifiers([]) } else { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        if let onPressWithModifiers { onPressWithModifiers([]) } else { onPress?() }
        return true
    }

    // MARK: Keyboard

    /// With Full Keyboard Access on (System Settings > Keyboard > Keyboard
    /// navigation), Tab reaches the item and Space or Return presses it; the
    /// system focus ring follows its pill.
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }
    /// The item has keyboard focus (its glyph draws at full strength).
    private(set) var isKeyFocused = false { didSet { if isKeyFocused != oldValue { needsDisplay = true } } }

    override func becomeFirstResponder() -> Bool {
        isKeyFocused = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isKeyFocused = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.function).isEmpty,
              [" ", "\r", "\u{3}"].contains(event.charactersIgnoringModifiers ?? "") else { return super.keyDown(with: event) }
        _ = accessibilityPerformPress()
    }

    override var focusRingMaskBounds: NSRect { pill.frame }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: pill.frame, xRadius: pill.cornerRadius, yRadius: pill.cornerRadius).fill()
    }
}

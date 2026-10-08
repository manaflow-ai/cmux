import AppKit
import CmuxAgentBrands
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
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let badge = UnreadBadgeView()
    let avatarView = SidebarAvatarView()
    /// Set only by the hover owner (`PointerHover`, cx-3wu5): the pointer
    /// now over the row's frame now. Leaving also ends a press.
    private(set) var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            if !isHovered { isPressed = false }
            pointerChanged()
        }
    }
    private var pointerHover: PointerHover?
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
        [icon, title, badge, avatarView].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        pointerHover = PointerHover(self) { [weak self] hovering in self?.isHovered = hovering }
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

    /// The unread badge draws (tests).
    var isBadgeShown: Bool { !badge.isHidden }
    /// The glyph's frame (tests).
    var glyphFrame: CGRect { icon.frame }
    /// The badge's frame while it draws (tests).
    var badgeFrame: CGRect? { badge.isHidden ? nil : badge.frame }

    func configure(_ info: SidebarItemInfo, style: Style) {
        guard info != self.info || style != self.style else { return }
        // A selection change paints at once (SIDEBAR-SELECTION-NO-TRAVEL-ANIMATION).
        if info.isActive != self.info.isActive { fadesNextFill = false }
        self.info = info
        self.style = style
        title.stringValue = style == .favorite ? info.caption ?? info.title : info.title
        title.isHidden = style.isIconOnly
        title.alignment = style == .favorite ? .center : .natural
        // Icons and tiles have no room for a count: unread items show a dot
        // at the glyph's top trailing corner (the rail, like the Codex app's).
        let unread: UnreadState
        if info.unreadDot {
            unread = .dot
        } else if style == .favorite {
            unread = (info.badge ?? 0) > 0 ? UnreadState.dot : UnreadState.none
        } else if style.isIconOnly {
            unread = isRailButton && (info.badge ?? 0) > 0 ? UnreadState.dot : UnreadState.none
        } else {
            unread = info.badge.map(UnreadState.count) ?? UnreadState.none
        }
        badge.configure(unread)
        // VoiceOver hears the count even where no badge draws (icons).
        setAccessibilityValue(info.unreadDot ? Strings.unreadDot : info.badge.map { String($0) })
        // An icon names itself (and its shortcut) in its tooltip; a tile's
        // caption can truncate, so it keeps the full title.
        toolTip = style.isIconOnly ? info.toolTip : style == .favorite ? info.title : nil
        setAccessibilityLabel(info.title)
        applyAvatar()
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
            avatarView.isStrong = strong
            icon.contentTintColor = wells && info.color != nil ? Palette.textOnPrimary
                : style == .favorite ? Palette.textPrimary
                : info.isActive || isRailButton || strong ? Palette.textPrimary : Palette.textSecondary
        }
    }

    /// The pill's fill: pressed, then active, then hovered, then the
    /// tile's resting fill. A tile rests on `hoverFill`, so its hover takes
    /// the next tonal step (`selectionFill`) and still shows a change (R97).
    var fill: NSColor? {
        let state = ChromeHover.State(hovering: isHovered, pressed: isPressed, selected: info.isActive)
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

        if layoutAvatar(in: b) { return }
        // Row size beside a title, like a workspace row's type glyph; inside a list well, the well's
        // glyph size; a rail button's own glyph size.
        let glyphSide = isRailButton ? SidebarStyle.railGlyphSize : style == .list ? SidebarStyle.wellGlyphSize : SidebarStyle.kindGlyphSize
        if style == .icon, !isRailButton, let (image, frame) = inkSizedGlyph(centeredIn: b) {
            icon.image = image
            icon.frame = frame
        } else {
            icon.image = glyphImage(side: glyphSide)
            icon.frame = alignedGlyphFrame(side: glyphSide, centeredIn: iconFrame)
        }
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
        // A dot is round: as tall as it is wide, centered on the row.
        let badgeHeight = badge.state == .dot ? badgeWidth : bh
        badge.frame = NSRect(x: badgeX, y: (b.height - badgeHeight) / 2, width: badgeWidth, height: badgeHeight)
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

    /// The item's registry icon at `side` points; without one, its SF Symbol at the matching text size.
    private func glyphImage(side: CGFloat) -> NSImage? {
        if let emoji = info.emoji { return Self.emojiImage(emoji, side: side) }
        if let brand = info.brand, let mark = AgentBrandCatalog.templateImage(brand: brand, size: side) { return mark }
        if let name = info.icon { return NSImage.icon(name, size: side) }
        let symbol = NSImage(systemSymbolName: info.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: side * 0.8, weight: .regular))
        return symbol ?? NSImage.icon(.appGeneric, size: side)
    }

    /// `emoji` drawn as a text glyph filling a `side` square (in color, not a template).
    static func emojiImage(_ emoji: String, side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let text = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: side * 0.85)])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
    }

    /// An icon-only item's glyph (the footer's avatar and gear): drawn so its
    /// ink, not its image box, is `iconInkSize` across and centered in `box`.
    /// Icons leave different margins in their square, so equal image boxes
    /// read as different sizes. Nil when the glyph draws nothing.
    private func inkSizedGlyph(centeredIn box: NSRect) -> (NSImage, NSRect)? {
        let nominal = SidebarStyle.kindGlyphSize
        let glyph = "\(info.emoji ?? "")|\(info.brand.map { "\($0)" } ?? "")|\(info.icon?.rawValue ?? "")|\(info.symbol)"
        guard let probe = glyphImage(side: nominal), let ink = SidebarGlyphInk.shared.box(of: probe, glyph: glyph),
              max(ink.width, ink.height) > 0 else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let snap = { (value: CGFloat) in (value * scale).rounded() / scale }
        let side = snap(nominal * Self.iconInkSize / max(ink.width, ink.height))
        guard let image = glyphImage(side: side), let drawn = SidebarGlyphInk.shared.box(of: image, glyph: glyph) else { return nil }
        return (image, NSRect(x: snap(box.midX - drawn.midX), y: snap(box.midY - drawn.midY), width: side, height: side))
    }

    /// The ink extent of an icon-only item's glyph, in points: the avatar's
    /// circle and the gear's teeth both span it.
    static var iconInkSize: CGFloat { SidebarStyle.kindGlyphSize }

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
    }

    // MARK: Pointer


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

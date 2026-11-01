import AppKit
import CmuxAgentBrands
import CmuxNextDesign
import CmuxNextIcons
import Observation
import QuartzCore

/// One item of a pinned section: a row (built-in or list look) or a tray
/// tile. A pill shows on hover, while pressed and while the item is
/// active, in the shared chrome fills (`ChromeHover.fillColor`), fading on
/// pointer changes. The rail's icon-only items show unread items as a dot
/// on the glyph instead of a count; the sidebar's own icon looks hide them.
class SidebarItemRowView: NSView {
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
    /// Modifier-aware activation for controls whose action has a one-shot
    /// Option override. Plain activations continue through `onPress`.
    var onPressWithModifiers: ((NSEvent.ModifierFlags) -> Void)?
    var onContextMenu: ((NSEvent, NSView) -> Void)?
    /// True: the item acts on mouse-down, as workspace rows do (every item but a new-tab
    /// launcher: `LayoutItemRef.activatesOnPress`); false: on release.
    var activatesOnPress = false
    /// Whether a press on the item may drag it (`LayoutItem.isMovable`, set from the item's data): false for Home,
    /// whose press-and-drag is a plain press (no lift, no drag, no drop).
    var isMovable = true
    /// The current press already ran the action on mouse-down; its release does not run it again.
    private var activatedOnPress = false
    /// The sidebar's edit mode (`SidebarItemRowView+Editing`): the item wiggles and shows its ✕
    /// (`onRemove`), and a press only drags it.
    var isEditing = false { didSet { if isEditing != oldValue { editingChanged() } } }
    var onRemove: (() -> Void)?
    var removeButton: SidebarIconButton?
    /// A workspace tile's hover control (`SidebarItemRowView+HoverActions`): its menu. A pinned item draws no
    /// hover close (Lawrence msg 19392); Close Workspace is in that menu.
    var onMore: (() -> Void)?
    var hoverMore: OverflowButton?
    var wiggleSize: CGSize = .zero

    private(set) var info = SidebarItemInfo(title: "", symbol: "circle")
    private(set) var style = Style.builtIn
    /// The row's fill (internal so tests can read its frame and radius).
    let pill = CALayer()
    let chip = CALayer()
    let icon = DecorativeImageView() // the row's label names the item
    private let pin = DecorativeImageView() // a pinned row's leading pin; Pinned's header names it
    let title = ChromeLabel(labelWithString: "")
    let badge = UnreadBadgeView()
    /// The blue unread dot of a workspace row (`info.unreadDot`, Home's unread): a row draws it on
    /// the trailing column, as a workspace row does; an icon look dots its glyph with `badge`.
    let rowBadge = RowBadgeView()
    let avatarView = SidebarAvatarView()
    /// The workspace item's status: the shared indicator (`info.activity`).
    let activity: StatusIndicatorView = {
        let view = StatusIndicatorView()
        (view.tracksWindowOcclusion, view.usesStatusColors) = (true, true) // the sidebar's status colors (Lawrence msg 11983)
        return view
    }()
    /// Set only by the hover owner (`PointerHover`, cx-3wu5): the pointer
    /// now over the row's frame now. Leaving also ends a press.
    private(set) var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            if !isHovered { isPressed = false }
            pointerChanged()
            // A workspace tile's more button shows on hover (a pinned item has no hover close).
            if info.workspace != nil { needsLayout = true }
        }
    }
    private var pointerHover: PointerHover?
    private(set) var isPressed = false { didSet { if isPressed != oldValue { pointerChanged() } } }
    /// A menu opened from this row is open. The profile control's (the whole pill is that control): the pill holds
    /// the selected step (between hover and pressed) until the menu closes. A workspace tile's hover more button's: the
    /// hover controls stay shown and only that button lights, never the pill (Leo 2026-10-27: "why are you giving it
    /// the entire row when it's only this small little section?").
    var showsMenu = false {
        didSet {
            guard showsMenu != oldValue else { return }
            // The menu's tracking takes the release: no mouseUp ends the press.
            isPressed = false
            pointerChanged()
            needsLayout = true
        }
    }
    /// The next fill change came from the pointer, so it fades.
    private var fadesNextFill = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for decoration in [pill, chip] {
            decoration.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(),
                                  "borderColor": NSNull(), "borderWidth": NSNull()]
            decoration.cornerCurve = .continuous
            layer?.addSublayer(decoration)
        }
        icon.imageScaling = .scaleProportionallyDown
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        [pin, icon, title, badge, rowBadge, avatarView, activity].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        // Keyboard focus is the fill's next tonal step (`fill`), never the system's blue ring.
        focusRingType = .none
        pointerHover = PointerHover(self) { [weak self] hovering in self?.isHovered = hovering }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }
    /// A drag from a press (window points): true once the region drags.
    var onDragged: ((NSPoint, NSEvent) -> Bool)?
    var onDragEnded: ((_ windowPoint: NSPoint) -> Void)? // the release, which decides the drop
    /// Every press, before it acts: a drag an earlier press left held ends (its release went elsewhere).
    var onPressBegan: (() -> Void)?
    private var pressLocation: NSPoint?
    private var didDrag = false
    /// The press's modifiers, which the release acts with (Option opens a workspace).
    private var pressModifiers: NSEvent.ModifierFlags = []
    /// One observation of the Notifications glyph look is registered at a time.
    private var observesNotificationIcon = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(_ info: SidebarItemInfo, style: Style) {
        guard info != self.info || style != self.style else { return }
        // A selection change paints at once (SIDEBAR-SELECTION-NO-TRAVEL-ANIMATION).
        if info.isActive != self.info.isActive || info.isSecondarySelected != self.info.isSecondarySelected { fadesNextFill = false }
        self.info = info
        self.style = style
        title.stringValue = style == .favorite ? info.caption ?? info.title : info.title
        title.isHidden = style.isIconOnly
        pin.image = info.leadingPin ? NSImage.icon(.statePinned, size: SidebarStyle.leadingGlyphSide) : nil
        title.alignment = style == .favorite ? .center : .natural
        let trailingDot = info.unreadDot && !style.isIconOnly && style != .favorite
        rowBadge.configure(trailingDot ? [.success] : [], look: .plain)
        badge.notificationDot = info.unreadDot
        badge.configure(trailingDot ? .none : unreadState)
        activity.configure(info.activity, style: info.activityStyle)
        // VoiceOver hears the count even where no badge draws (icons).
        setAccessibilityValue(info.unreadDot ? Strings.unreadDot : info.badge.map { String($0) })
        // An icon names itself (and its shortcut) in its tooltip; a tile's
        // caption can truncate, so it keeps the full title.
        // The profile control draws no name, so its tooltip says who it is: the email.
        themedToolTip = info.avatar?.toolTip ?? (style.isIconOnly ? info.toolTip : style == .favorite ? info.title : nil)
        setAccessibilityLabel(info.accessibilityTitle ?? info.title)
        applyAvatar()
        setAccessibilitySelected(info.isActive || info.isSecondarySelected)
        alphaValue = info.isMissing ? 0.5 : 1
        needsLayout = true
        needsDisplay = true
    }

    override func updateLayer() {
        performWithTheme {
            ChromeHover.paint(pill, fill, animated: fadesNextFill)
            fadesNextFill = false
            // Increase Contrast adds a ring to the tint, in the theme's focus color.
            pill.borderColor = Palette.focusRing.cgColor
            pill.borderWidth = showsKeyFocus && NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                ? Metrics.lineWidth(1.5) : 0
            let wells = style == .list || style == .favorite
            // A tile's well is the raised surface on the tiles card (Safari's
            // favorites); a list row's well is the quieter hover step.
            let rest = style == .favorite ? Palette.elevatedBackground : Palette.hoverFill
            // A favicon draws in its own colors: on the resting well, not the workspace color.
            chip.backgroundColor = showsSwatchDot ? info.color.map(SidebarStyle.color)?.cgColor
                : wells ? ((info.favicon == nil ? info.color.map(SidebarStyle.color) : nil) ?? rest).cgColor : nil
            title.textColor = Palette.textPrimary
            // An icon is secondary at rest and full strength under the pointer
            // or keyboard focus (the footer's avatar and gear).
            let strong = (style == .icon || showsAvatar) && (isHovered || isPressed || showsMenu || showsKeyFocus)
            avatarView.isStrong = strong
            pin.contentTintColor = Palette.textSecondary
            let fallbackAgentTint = info.agentColor.flatMap { color in
                guard let brand = info.brand else { return SidebarStyle.color(color) }
                return AgentBrandCatalog.templateImage(brand: brand, size: SidebarStyle.kindGlyphSize) == nil
                    ? SidebarStyle.color(color) : nil
            }
            icon.contentTintColor = fallbackAgentTint
                ?? (wells && info.color != nil ? Palette.textOnPrimary
                : style == .favorite ? Palette.textPrimary
                : info.isActive || isRailButton || strong ? Palette.textPrimary : Palette.textSecondary)
        }
    }

    /// The pill's fill: pressed, then keyboard focus, then active, then
    /// hovered, then the tile's resting fill. A tile rests on `hoverFill`, so
    /// its hover takes the next neutral step (`ChromeHover.raisedHoverFill`, never
    /// the accent selection) and still shows a change (R97). Keyboard focus is one
    /// step past hover: `selectionFill`, or `pressedFill` over a fill that is
    /// already that (cx-wqn5).
    var fill: NSColor? {
        // A menu from the hover more button lights that button alone (`layoutHoverActions`), not the pill.
        let state = ChromeHover.State(hovering: isHovered, pressed: isPressed, selected: info.isActive || (showsMenu && !showsHoverActions))
        return performWithTheme {
            if showsKeyFocus, !isPressed {
                return info.isActive || style == .tile ? Palette.pressedFill : Palette.selectionFill
            }
            // In the multi-selection (Shift- or Cmd-click), as a selected list row draws.
            if info.isSecondarySelected, !isPressed { return Palette.secondarySelectionFill }
            guard style == .tile else { return ChromeHover.fillColor(state) }
            return ChromeHover.fillColor(state, rest: Palette.hoverFill)
        }
    }

    private func pointerChanged() {
        fadesNextFill = true
        needsDisplay = true
    }

    /// A text-only workspace item with a color (a pinned workspace with no icon): it draws the
    /// color as a dot before its title, as the workspace's list row does.
    var showsSwatchDot: Bool { info.textOnly && info.color != nil && !style.isIconOnly && style != .favorite }

    override func layout() {
        super.layout()
        let b = bounds
        layoutEditing()
        if style == .favorite { return layoutFavorite(b) }
        // Runs after the activity mark (defers run last first): the controls take the trailing end.
        defer { layoutHoverActions(in: b) }
        defer { layoutActivity(in: b) }
        let inset = SidebarStyle.horizontalInset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = isRailButton ? SidebarStyle.railIconBox : SidebarStyle.iconBox
        // A text-only workspace item beside its title draws no glyph (WORKSPACE-ROWS-NO-DEFAULT-ICON).
        let bare = info.textOnly && !style.isIconOnly
        // One leading inset for every row (Lawrence 2026-10-28, "home and pinned are not aligned"): the first ink
        // (a band row's glyph, a pinned row's pin) starts where a workspace row's text starts (its inset plus the
        // pill inset), and a title after that glyph starts at the one text column (`SidebarStyle.leadingTextX`).
        // A pinned row's own icon or color dot, when it has one, takes the text column after the pin.
        let columns = bandColumns(in: b)
        let pinFrame = info.leadingPin ? pinGlyphFrame(side: SidebarStyle.leadingGlyphSide, leading: columns.lead, height: b.height) : .zero
        // After a pin, the row's own icon, color dot and title move one icon column in.
        let inner = info.leadingPin ? bandColumns(in: b, after: columns.text - columns.lead) : columns
        let lead = style == .chip ? Metrics.space2 : inner.lead
        // A list row's icon frame is the grid's icon column box (16 compact, 20 comfortable); its glyph and well keep
        // their own `side`, centered in it, so the title is one 8 pt gap after the frame at both densities.
        let columnSide = style == .chip ? side : Swift.max(side, inner.iconBox)
        let iconFrame = style.isIconOnly
            ? NSRect(x: (b.width - side) / 2, y: (b.height - side) / 2, width: side, height: side)
            : NSRect(x: lead, y: (b.height - columnSide) / 2, width: columnSide, height: columnSide)
        let wellFrame = NSRect(x: iconFrame.midX - side / 2, y: iconFrame.midY - side / 2, width: side, height: side)
        pin.isHidden = !info.leadingPin
        pin.frame = pinFrame
        // Icon-only items keep their pill around the glyph (a full-width fill reads
        // as a selected row); the profile avatar's pill and click fill its square.
        let pillFrame = style.isIconOnly ? (showsAvatar ? b : iconFrame)
            : style == .chip ? b
            : NSRect(x: inset, y: 0, width: max(0, b.width - inset * 2), height: b.height)
        pill.frame = pillFrame
        pill.cornerRadius = isRailButton ? SidebarStyle.railTileCornerRadius : SidebarStyle.rowCornerRadius
        // A text-only workspace with a color draws it as its list row does: a dot before the title.
        let dot = SidebarStyle.dotSize
        chip.frame = showsSwatchDot ? NSRect(x: iconFrame.midX - dot / 2, y: (b.height - dot) / 2, width: dot, height: dot)
            : style == .list && !bare ? wellFrame : .zero
        chip.cornerRadius = showsSwatchDot ? dot / 2 : Metrics.space1 + 1
        CATransaction.commit()

        if layoutAvatar(in: b) { return }
        // Row size beside a title, like a workspace row's type glyph; inside a list well, the well's
        // glyph size; a rail button's own glyph size.
        let glyphSide = isRailButton ? SidebarStyle.railGlyphSize : style == .list ? SidebarStyle.wellGlyphSize : SidebarStyle.kindGlyphSize
        if bare {
            icon.image = nil
            icon.frame = .zero
        } else if style == .icon, !isRailButton, info.favicon == nil, !info.textOnly,
                  let (image, frame) = inkSizedGlyph(centeredIn: b) {
            icon.image = image
            icon.frame = frame
        } else {
            icon.image = glyphImage(side: glyphSide)
            // A bare glyph beside a title (Home, the band's rows) centers its ink on the icon column, as the pin and a
            // workspace row's icon do (Leo 2026-10-28: "the alignment"); a glyph in a well or a tile centers its square.
            icon.frame = style == .builtIn && !isRailButton ? inkCenteredGlyphFrame(side: glyphSide, centeredIn: iconFrame)
                : alignedGlyphFrame(side: glyphSide, centeredIn: iconFrame)
        }
        title.font = SidebarStyle.titleFont
        if style.isIconOnly {
            let dot = SidebarStyle.unreadDotSize
            badge.frame = NSRect(x: iconFrame.maxX - dot / 2, y: iconFrame.minY - dot / 2, width: dot, height: dot)
            title.frame = .zero
            return
        }
        let trailing = b.width
        let bh = SidebarStyle.badgeHeight
        let badgeWidth = badge.isHidden ? 0 : badge.preferredWidth
        var badgeX = style == .chip
            ? (badge.isHidden ? trailing : trailing - Metrics.space2 - badgeWidth)
            : SidebarStyle.trailingColumnFrame(rowWidth: b.width - inset, centerY: b.midY, side: badgeWidth).minX
        if let columnStart = layoutColumnMark(in: b) {
            // A count beside the column's mark (a Chief's) sits left of the column.
            badgeX = badge.isHidden || style == .chip ? columnStart : columnStart - Metrics.space2 - badgeWidth
        }
        // A dot is round: as tall as it is wide, centered on the row.
        let badgeHeight = badge.state == .dot ? badgeWidth : bh
        if style != .chip, !badge.isHidden {
            let index = !rowBadge.isHidden || activityOnColumn ? 1 : 0
            badgeX = columns.trailingCenter(index: index) - badgeWidth / 2
        }
        badge.frame = NSRect(x: badgeX, y: (b.height - badgeHeight) / 2, width: badgeWidth, height: badgeHeight)
        let th = ceil(title.intrinsicContentSize.height)
        let textX = (style == .chip ? iconFrame.maxX + Metrics.space2 : inner.text(hasLeadingMark: !bare || showsSwatchDot)) - SidebarStyle.labelCellPadding
        title.frame = NSRect(x: textX, y: SidebarStyle.textY(title, centerY: b.midY), width: max(0, activityLeading(before: badgeX) - Metrics.space2 - textX), height: th)
    }

    /// Places the row's trailing mark as a workspace row places its own: the blue unread dot, else
    /// the status (a band workspace that needs you or works, `info.activity`), centered on the
    /// trailing column (the group header chevron's x, `SidebarStyle+TrailingColumn`); a chip puts
    /// the dot after its label. Returns where the room left of the mark starts, nil with no mark.
    /// A workspace row's bounds are its fill; this row's fill is inset by `horizontalInset`, so the
    /// column is measured from the fill's end. Lawrence msg 11914: the status drew after the title,
    /// 3.5 pt right of the column every other dot and spinner shares.
    private func layoutColumnMark(in b: NSRect) -> CGFloat? {
        let columns = bandColumns(in: b)
        let column = columns.trailingCenter()
        if !rowBadge.isHidden {
            let side = rowBadge.cellSide, width = rowBadge.preferredWidth
            let x = style == .chip ? b.width - Metrics.space2 - width : column - width + side / 2, scale = window?.backingScaleFactor ?? 2
            rowBadge.frame = NSRect(x: SidebarStyle.pixelSnapped(x, scale: scale), y: SidebarStyle.pixelSnapped((b.height - side) / 2, scale: scale),
                                    width: width, height: side)
            guard style != .chip else { return rowBadge.frame.minX }
            return min(rowBadge.frame.minX, column - SidebarStyle.trailingSlotSide / 2)
        }
        guard activityOnColumn else { return nil }
        let side = SidebarStyle.indicatorSize, scale = window?.backingScaleFactor ?? 2
        func snapped(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        activity.frame = NSRect(x: snapped(column - side / 2), y: snapped((b.height - side) / 2), width: side, height: side)
        return min(activity.frame.minX, column - SidebarStyle.trailingSlotSide / 2)
    }

    /// The shared sidebar columns in this row's coordinates. A band row's bounds include the outer inset on
    /// both sides (its pill runs from `horizontalInset` to `width - horizontalInset`), so the columns are the list
    /// rows' measured from the pill: lead `horizontalInset` inside it, the trailing line 22.5 before its end.
    /// `after` moves lead and text right (a pinned row's icon and title, one icon column after the pin).
    func bandColumns(in b: NSRect, after: CGFloat = 0) -> SidebarColumns {
        let inset = SidebarStyle.horizontalInset
        return SidebarStyle.columns(rowWidth: b.width - inset, depth: info.indent, leadingOffset: inset + after)
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
        let dot = SidebarStyle.unreadDotSize
        badge.frame = NSRect(x: wellFrame.maxX - dot / 2 - 1, y: wellFrame.minY - dot / 2 + 1, width: dot, height: dot)
        layoutActivity(onGlyph: wellFrame)
    }

    /// The cache key of the pin's ink (`SidebarGlyphInk`).
    static let pinGlyph = "pin|\(IconName.statePinned.rawValue)"

    /// The leading pin's frame: its drawn ink, not its square, centers on the icon column of a slot starting at
    /// `leading` (where an unpinned workspace row's icon starts, `SidebarStyle.iconColumnCenterX`) and on the row,
    /// on the device pixel grid. The pin's square leaves a margin around its ink (Leo 2026-10-21), and its ink is
    /// narrower than a row icon, so ink-leading drew it left of the icons' center (Leo 2026-10-28: "the alignment").
    private func pinGlyphFrame(side: CGFloat, leading: CGFloat, height: CGFloat) -> NSRect {
        let scale = window?.backingScaleFactor ?? 2
        let snap = { (value: CGFloat) in (value * scale).rounded() / scale }
        let column = SidebarStyle.iconColumnCenterX(leading: leading)
        guard let image = pin.image, let ink = SidebarGlyphInk.shared.box(of: image, glyph: Self.pinGlyph) else {
            return NSRect(x: snap(column - side / 2), y: snap((height - side) / 2), width: side, height: side)
        }
        return NSRect(x: snap(column - ink.midX), y: snap(height / 2 - ink.midY), width: side, height: side)
    }

    /// The pin's drawn ink in the row's coordinates; nil without a pin (tests).
    var pinInkFrame: CGRect? {
        guard !pin.isHidden, let image = pin.image, let ink = SidebarGlyphInk.shared.box(of: image, glyph: Self.pinGlyph) else { return nil }
        return ink.offsetBy(dx: pin.frame.minX, dy: pin.frame.minY)
    }

    /// The drawn ink of the item's glyph in the row's coordinates; nil when no glyph draws (tests).
    var glyphInkFrame: CGRect? {
        guard !icon.isHidden, let image = icon.image, icon.frame.width > 0,
              let ink = SidebarGlyphInk.shared.box(of: image, glyph: glyphKey) else { return nil }
        return ink.offsetBy(dx: icon.frame.minX, dy: icon.frame.minY)
    }

    /// The cache key of the item's glyph ink (`SidebarGlyphInk`): what draws it, not its size.
    var glyphKey: String {
        let iconKey = info.icon == .notification ? "\(info.icon?.rawValue ?? "")#\(NotificationIconLook.tunable.value.rawValue)" : info.icon?.rawValue ?? ""
        return "\(info.emoji ?? "")|\(info.brand.map { "\($0)" } ?? "")|\(iconKey)|\(info.symbol)|\(info.favicon == nil ? "" : info.title)"
    }

    /// The item's registry icon at `side` points; without one, its SF Symbol at the matching text size.
    private func glyphImage(side: CGFloat) -> NSImage? {
        if let favicon = info.favicon { return NSImage(cgImage: favicon.image, size: NSSize(width: side, height: side)) }
        if let emoji = info.emoji { return Self.emojiImage(emoji, side: side) }
        // An empty title has no initial: the item's neutral symbol keeps an icon-only look visible.
        if info.textOnly, let initial = Self.initialImage(info.caption ?? info.title, side: side) { return initial }
        if let brand = info.brand, let mark = AgentBrandCatalog.templateImage(brand: brand, size: side) { return mark }
        var glyphIcon = info.icon, symbolName = info.symbol
        // The Notifications item draws the Debug Settings glyph (`NotificationIconLook`, cx-epgo).
        if glyphIcon == .notification {
            let look = observedNotificationIcon()
            glyphIcon = look.icon
            symbolName = look.symbol
        }
        if let name = glyphIcon { return NSImage.icon(name, size: side) }
        guard NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) != nil else { return NSImage.icon(.appGeneric, size: side) }
        return NSImage.icon(symbol: symbolName, size: side)
    }

    /// Reads the Notifications glyph look and lays the row out again once
    /// when Debug Settings changes it (no polling).
    private func observedNotificationIcon() -> NotificationIconLook {
        guard !observesNotificationIcon else { return NotificationIconLook.tunable.value }
        observesNotificationIcon = true
        return withObservationTracking {
            NotificationIconLook.tunable.value
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observesNotificationIcon = false
                self?.needsLayout = true
            }
        }
    }

    /// An icon-only item's glyph (the footer's avatar and gear): drawn so its
    /// ink, not its image box, is `iconInkSize` across and centered in `box`.
    /// Icons leave different margins in their square, so equal image boxes
    /// read as different sizes. Nil when the glyph draws nothing.
    private func inkSizedGlyph(centeredIn box: NSRect) -> (NSImage, NSRect)? {
        let nominal = SidebarStyle.kindGlyphSize
        let iconKey = info.icon == .notification ? "\(info.icon?.rawValue ?? "")#\(NotificationIconLook.tunable.value.rawValue)" : info.icon?.rawValue ?? ""
        let glyph = "\(info.emoji ?? "")|\(info.brand.map { "\($0)" } ?? "")|\(iconKey)|\(info.symbol)"
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

    /// A `side` square whose drawn ink, not its square, centers in `box` on both axes, on the device pixel grid: a
    /// glyph with uneven margins still lands on the icon column and its title's center line. Falls back to centering
    /// the square when the glyph draws nothing measurable.
    private func inkCenteredGlyphFrame(side: CGFloat, centeredIn box: NSRect) -> NSRect {
        let centered = alignedGlyphFrame(side: side, centeredIn: box)
        guard let image = icon.image, let ink = SidebarGlyphInk.shared.box(of: image, glyph: glyphKey) else { return centered }
        let scale = window?.backingScaleFactor ?? 2
        let snap = { (value: CGFloat) in (value * scale).rounded() / scale }
        return NSRect(x: snap(box.midX - ink.midX), y: snap(box.midY - ink.midY), width: side, height: side)
    }

    /// The glyph drawn now (tests).
    var glyphImage: NSImage? { icon.image }
    /// Where the caption's text draws (tests): its alignment rect, without the label cell's 2 pt side
    /// padding, so it compares with a workspace title (a marquee label, which draws at its frame's edge).
    var titleFrame: CGRect {
        guard !title.isHidden else { return .zero }
        return title.frame.width > 0 ? title.alignmentRect(forFrame: title.frame) : title.frame
    }
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
        onPressBegan?()
        let point = convert(event.locationInWindow, from: nil)
        guard pill.frame.contains(point) else { return super.mouseDown(with: event) }
        isPressed = true
        pressLocation = event.locationInWindow
        pressModifiers = event.modifierFlags
        didDrag = false
        activatedOnPress = activatesOnPress && !isEditing
        guard activatedOnPress else { return }
        activate(with: pressModifiers)
        // The profile control's menu runs its own tracking loop and takes the release: no mouseUp
        // follows, so the pressed fill must not stay.
        if NSEvent.pressedMouseButtons & 1 == 0 { isPressed = false }
    }

    /// Past the drag threshold the region reorders in place (R77). An item that cannot move drags nothing.
    override func mouseDragged(with event: NSEvent) {
        guard isMovable, let pressLocation, onDragged?(pressLocation, event) == true else { return super.mouseDragged(with: event) }
        didDrag = true
        isPressed = false
    }

    /// An item that does not open on press (a new-tab launcher) acts on release, like a
    /// button: a press that became a drag (or left the item first) never runs it. Acting
    /// on the press made a tab under a launcher the user only meant to move.
    override func mouseUp(with event: NSEvent) {
        let dragged = didDrag
        let activated = activatedOnPress
        if dragged { onDragEnded?(event.locationInWindow) }
        pressLocation = nil
        didDrag = false
        activatedOnPress = false
        guard isPressed else { return super.mouseUp(with: event) }
        isPressed = false
        guard !dragged, !activated, !isEditing, pill.frame.contains(convert(event.locationInWindow, from: nil)) else { return }
        activate(with: pressModifiers)
    }

    /// Whether a press on the item is still held (its release has not come).
    var holdsPress: Bool { pressLocation != nil }

    /// Ends the item's press without acting: the gesture that owned it ended elsewhere (the list's one gesture end,
    /// `SidebarListView.endPointerGesture`), so its release never comes here. The pressed fill clears, and a later
    /// drag or release of that press does nothing.
    func endPress() {
        pressLocation = nil
        didDrag = false
        activatedOnPress = false
        isPressed = false
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // Off its window no release reaches the item: its press ends with its look.
        if newWindow == nil { endPress() }
    }

    private func activate(with modifiers: NSEvent.ModifierFlags) {
        if let onPressWithModifiers { onPressWithModifiers(modifiers) } else { onPress?() }
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
        if isEditing { return false }
        if let onPressWithModifiers { onPressWithModifiers([]) } else { onPress?() }
        return true
    }

    // MARK: Keyboard

    /// With Full Keyboard Access on (System Settings > Keyboard > Keyboard
    /// navigation), Tab reaches the item and Space or Return presses it; the
    /// system focus ring follows its pill.
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled || SidebarArrowWalk.isMovingFocus }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }
    /// The item has keyboard focus (its glyph draws at full strength).
    private(set) var isKeyFocused = false { didSet { if isKeyFocused != oldValue { needsDisplay = true } } }
    /// Keyboard focus as drawn: only while the window is key.
    private var showsKeyFocus: Bool { KeyWindowRepaint.showsFocus(self, focused: isKeyFocused) }
    private lazy var keyRepaint = KeyWindowRepaint(self)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyRepaint.track()
    }

    override func becomeFirstResponder() -> Bool {
        isKeyFocused = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isKeyFocused = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        if editingKeyDown(event) { return }
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.function).isEmpty,
              [" ", "\r", "\u{3}"].contains(event.charactersIgnoringModifiers ?? "") else { return super.keyDown(with: event) }
        _ = accessibilityPerformPress()
    }
}

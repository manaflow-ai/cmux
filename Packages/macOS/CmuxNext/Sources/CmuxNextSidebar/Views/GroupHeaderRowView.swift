import AppKit
import CmuxNextDesign
import CmuxNextIcons
import Observation
import QuartzCore

/// Group header (Lawrence 2026-10-11, cx-qno.22: the solid color bar is
/// back, over cx-25az's dot-only header and cx-fo2t's no-hover header): the
/// cx-rcby colored pill chip, one full-width rounded bar in the group's
/// color (Lawrence 2026-10-08), with the members' line starting under it;
/// the name starts on the ungrouped rows' leading column (an icon there, the name
/// where their text starts), one left edge for headers and ungrouped rows
/// (cg-design-judge 2026-10-14). Every glyph on the bar (name, count, icon, pin,
/// chevron, + and more) takes one ink chosen from the bar's color: white or
/// near-black, whichever reads better (`GroupTint.headerChip`, 4.5:1 also on
/// hover, drop and pressed). The + and the
/// more button show only on hover, keyboard focus or while the editor is
/// open; a hover fades them in and out (opacity only, `MotionFade.hoverReveal`,
/// u2397). Hover and a
/// drop take tonal steps over the bar's color. Type and glyphs scale with the row height
/// (the sidebar density setting). A collapsed group shows its loading spinner on the
/// chevron's column at rest and beside the + and more on hover; its member count and
/// unread total only when their settings are on (Lawrence 2026-10-20). Minimal mode keeps
/// the bar, only shorter: a hairline header read as a stray line, not a group (Lawrence
/// 2026-10-18, over #19936). The more button opens the group editor (cx-rcby); a right-click
/// shows the group's menu (cx-a9h6); a plain click anywhere else only collapses or expands
/// (Lawrence 2026-10-20).
final class GroupHeaderRowView: SidebarRowView {
    let name = SidebarRowView.label(font: SidebarStyle.headerFont)
    /// A collapsed group's member count, after the name.
    private let count = SidebarRowView.label(font: SidebarStyle.headerFont)
    /// The disclosure chevron: one glyph that turns as the group opens and closes (Lawrence msg 15763).
    private let chevron = DisclosureChevronView()
    /// The members' roll-up, in the sidebar's status colors (Lawrence msg 11983).
    private let activity: StatusIndicatorView = { let view = StatusIndicatorView(); view.usesStatusColors = true; return view }()
    /// The spinner's slot: it fades and collapses its width as loading starts and stops (u-group-header-detail).
    private lazy var activitySlot = SidebarRevealSlotView(activity) { [weak activity] in activity?.showsGlyph ?? false }
    /// Loading stopped: the spinner keeps drawing while its slot fades and collapses, then goes idle.
    private var activityEnding = false
    /// The next layout came from a status change, not a reload: the spinner's slot animates.
    private var fadesNextActivity = false
    private let badge = UnreadBadgeView()
    private let pin = DecorativeImageView()
    /// The group's icon inside its chip, before the name (`workspace-group-icon-v1`).
    let glyph = SidebarIconView()
    /// The row's fill: the band (`SidebarGroupHeaderStyle.band` and `.wash`); internal so tests can
    /// read its frame and radius.
    let pill = CALayer()
    /// The group's color as a dot on its line (cx-25az, Leo 2026-10-10: no full
    /// pastel fill): the line starts under it and runs to the last member.
    let dot = CALayer()
    /// The more button (the shared ⋮, `OverflowButton`): the group editor, as a click on the
    /// name (cx-rcby, Lawrence 2026-10-08); a right-click shows the group's flat menu.
    let moreButton = OverflowButton(label: GroupEditorStrings.more)
    /// The add button (+): a new workspace at the end of the group (cmuxterm-hq#1829,
    /// the Edge group header). Shows with the more button.
    let addButton = SidebarIconButton(icon: .actionAdd, pointSize: { Metrics.smallIconSize - Metrics.space1 },
                                      label: GroupEditorStrings.newWorkspace)
    private var pinned = false
    /// A remote group's machine mark (``SidebarGroup/machine``, ``SidebarHostGroupLook``).
    let machineMark = DecorativeImageView()
    /// A remote group's status dot, in the machine header's colors (`SectionHeaderRowView.tone`).
    let machineDot = CALayer()
    /// A remote group's status in words (``SidebarHostGroupLook/markAndWords``).
    private let machineWords = SidebarRowView.label(font: SidebarStyle.headerFont)
    private var machineTone: SectionHeaderRowView.StatusTone?
    private var machine: SidebarMachine?
    private var hostLook: SidebarHostGroupLook = .trailingMarkAndDot
    /// Archived in the sidebar document: the bar and its ink draw dimmed (`SidebarStyle.archivedAlpha`).
    private var archived = false
    private var hasIcon = false
    private var tint: GroupTint = .palette(.grey)
    private var collapsed = false
    private var chevronFrame: CGRect = .zero
    private var chevronIcon: IconName = .disclosureExpanded
    /// The header has shown a group since it was made or recycled: its first show takes the chevron's angle at once.
    private var configuredOnce = false
    var isDropTarget = false { didSet { if isDropTarget != oldValue { needsDisplay = true } } }
    /// Arrow keys stopped here (`SidebarListView+GroupKeys`): a focus ring, not a selection.
    var isKeyboardFocused = false { didSet { if isKeyboardFocused != oldValue { needsLayout = true; needsDisplay = true } } }
    /// The group editor is open for this group. Its trigger, the more button, stays shown and lit while it is open,
    /// though the pointer leaves for the editor (Leo 2026-10-26: "you keep it on when you click ... the popover"); the
    /// bar keeps its own fill, so only that button lights (Leo 2026-10-27: "Don't ever do that.").
    var isEditing = false {
        didSet {
            guard isEditing != oldValue else { return }
            moreButton.showsMenu = isEditing
            needsLayout = true
            needsDisplay = true
        }
    }
    /// How far this header's frame reaches left of its members' x, over their rail (`SidebarListView.railReach(for:)`):
    /// the bar and the dot start there, at the rail's left edge, and the name keeps the members' text column.
    var railReach: CGFloat = 0 { didSet { if railReach != oldValue { needsLayout = true } } }
    /// Shows the group's full menu: VoiceOver's More Group Actions (a right-click shows the same menu).
    var onMore: (() -> Void)?
    /// Opens the group editor (name, color and actions): the more button and VoiceOver's Edit action.
    var onEdit: (() -> Void)?
    var onAdd: (() -> Void)?

    override var interactiveSubviews: [NSView] { [addButton, moreButton] }

    required init(key: SidebarRowKey) {
        super.init(key: key)
        layer?.addSublayer(pill)
        layer?.addSublayer(dot)
        layer?.addSublayer(machineDot)
        machineDot.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
        pill.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
        dot.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
        [glyph, name, count, pin, chevron, activitySlot, badge, machineMark, machineWords, addButton, moreButton].forEach(addSubview)
        // The header's label says the name, the count and (through AXExpanded) the chevron.
        moreButton.onPress = { [weak self] in self?.onEdit?() }
        addButton.onPress = { [weak self] in self?.onAdd?() }
        // The + and more show only on hover; VoiceOver reaches the editor and the menu here always.
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: GroupEditorStrings.editor) { [weak self] in
                self?.onEdit?()
                return self?.onEdit != nil
            },
            NSAccessibilityCustomAction(name: GroupEditorStrings.moreActions) { [weak self] in
                self?.onMore?()
                return self?.onMore != nil
            },
            NSAccessibilityCustomAction(name: GroupEditorStrings.newWorkspace) { [weak self] in
                guard let self, let onAdd = self.onAdd else { return false }
                onAdd()
                return true
            },
        ])
    }

    override func prepareForReuse(key: SidebarRowKey) {
        super.prepareForReuse(key: key)
        isDropTarget = false
        isKeyboardFocused = false
        isEditing = false
        collapsed = false
        configuredOnce = false
        chevron.setOpen(true, animated: false)
        activityEnding = false
        activity.configure(.idle)
        onMore = nil
        onEdit = nil
        onAdd = nil
    }

    private struct Content: Hashable {
        var group: SidebarGroup
        var childCount: Int
        var collapsed: Bool
        var fontSize: CGFloat
        var details: GroupHeaderDetails
        var status: StatusIndicatorState?
        var look: SidebarHostGroupLook
    }

    /// Shows `group`. A collapsed header shows its loading spinner on the right; `details` turns
    /// on its member count, unread total and other states (all off by default).
    ///
    /// `status` is the header's roll-up over its whole subtree (``SidebarGroup/statusRollUp(collapsed:)``
    /// of the group and its subgroups); nil rolls up `group`'s own members.
    func configure(_ group: SidebarGroup, row: SidebarRow, details: GroupHeaderDetails = GroupHeaderDetails(),
                   status rollUp: StatusIndicatorState? = nil, animated: Bool) {
        let content = Content(group: group, childCount: row.childCount, collapsed: row.isCollapsed,
                              fontSize: SidebarStyle.headerFont.pointSize, details: details, status: rollUp,
                              look: group.hostLook)
        guard needsConfigure(content) else { return }
        tint = group.tint
        name.stringValue = group.name
        pinned = group.isPinned
        archived = group.isArchived
        hasIcon = group.icon != nil
        glyph.configure(icon: group.icon)
        hostLook = group.hostLook
        configureMachine(group.machine)
        pin.image = pinned ? NSImage.icon(.statePinned, size: SidebarStyle.leadingGlyphSide) : nil
        collapsed = row.isCollapsed
        count.stringValue = details.memberCount && collapsed && row.childCount > 0 ? "\(row.childCount)" : ""
        chevronIcon = Self.disclosureIcon(collapsed: collapsed)
        // One right-pointing glyph turned a quarter turn when open: a user's fold turns it as the rows slide.
        chevron.setImage(NSImage.icon(.disclosureCollapsed, size: .iconRowSize(forLabelPointSize: Metrics.smallIconSize - Metrics.space2)))
        chevron.setOpen(!collapsed, animated: animated && configuredOnce)
        configuredOnce = true
        // Lawrence 2026-10-20: "All we care about is the loading"; msg 11983: and blue, orange and red.
        let status = collapsed && details.otherStates ? group.aggregateActivity : rollUp ?? group.statusRollUp(collapsed: collapsed)
        if status.isVisible {
            activityEnding = false
            activity.configure(status)
        } else if activity.state.isVisible {
            activityEnding = true
        }
        fadesNextActivity = animated
        let unread = group.unreadTotal
        badge.configure(details.unreadCount && collapsed && unread > 0 ? .count(unread) : .none)
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel(group.machine.map { "\(group.name), \(SectionHeaderRowView.statusWords($0.status))" }
            ?? "\(group.name), \(Strings.groupCount(row.childCount))")
        setAccessibilityIdentifier("cmux.sidebar.group.\(group.id.rawValue)")
        moreButton.setAccessibilityIdentifier("cmux.sidebar.group.\(group.id.rawValue).more")
        addButton.setAccessibilityIdentifier("cmux.sidebar.group.\(group.id.rawValue).add")
        setAccessibilityHelp(collapsed ? GroupEditorStrings.expand : GroupEditorStrings.collapse)
        setAccessibilityExpanded(!collapsed)
        needsLayout = true
        needsDisplay = true
    }

    /// The disclosure convention of Finder and Edge (cx-fo2t): open points
    /// down, collapsed points right.
    private static func disclosureIcon(collapsed: Bool) -> IconName {
        collapsed ? .disclosureCollapsed : .disclosureExpanded
    }

    /// A state fill on the bar (hover, drop); the bar itself always shows. The open editor lights its more button only.
    override var debugArchived: Bool { archived }
    override var debugFill: Bool { super.debugFill || isHovered || isDropTarget }
    override var debugDisclosure: (icon: String, frame: CGRect, shown: Bool)? { (chevronIcon.rawValue, chevron.frame, !chevron.isHidden) }

    override var titleFrame: NSRect { name.frame }
    /// The unread state the header's badge shows (nested-groups tests: a folded parent's roll-up).
    var debugBadge: UnreadState { badge.state }
    /// Whether the header shows a loading or activity mark.
    var debugActivityVisible: Bool { activity.state.isVisible }
    /// The member count a collapsed header shows, nil when it shows none.
    var countText: String? { count.isHidden || count.stringValue.isEmpty ? nil : count.stringValue }
    /// The count's label, laid out (`SidebarGroupChromeLookTests`).
    var countLabel: ChromeLabel { count }
    /// The one ink every glyph on the header takes.
    var ink: NSColor? { name.textColor }
    /// The group chip (`GroupLabelBandTests`): a click here opens the editor.
    var labelFrame: NSRect { pill.frame }
    /// The header's leading mark the members' rail lines up with: the bar, or the quiet styles' dot.
    var leadingMarkFrame: NSRect { pill.isHidden ? dot.frame : pill.frame }
    /// The width the name needs to draw whole (`GroupLabelBandTests`).
    var titleIntrinsicWidth: CGFloat { Self.drawnWidth(name) }
    /// The width a header label needs to draw its text whole: its text in the font it draws in,
    /// plus the cell's text inset on both sides. The label's bare measured width is short of it
    /// (a live capture cut "Frontend" to "Fronte…" and clipped the count's digit).
    private static func drawnWidth(_ label: ChromeLabel) -> CGFloat {
        let font = label.font ?? SidebarStyle.headerFont
        let text = ceil((label.stringValue as NSString).size(withAttributes: [.font: font]).width)
        return max(ceil(label.intrinsicContentSize.width), text + 2 * Metrics.space2)
    }
    /// The group's name and icon: the editor opened by Return or Rename lines up under it (a
    /// plain click here only collapses or expands, as on the rest of the bar).
    var nameHitFrame: NSRect {
        let start = hasIcon ? glyph.frame.minX : name.frame.minX
        return NSRect(x: start - Metrics.space2, y: 0, width: name.frame.maxX - start + 2 * Metrics.space2, height: bounds.height)
    }
    override var titleFont: NSFont { name.font ?? SidebarStyle.headerFont }
    /// The label draws its text its padding (the alignment inset) in from its frame, the first
    /// baseline `firstBaselineOffsetFromTop` below its top.
    override var titlePenOrigin: NSValue? {
        NSValue(point: NSPoint(x: name.frame.minX + name.alignmentRectInsets.left, y: name.frame.minY + name.firstBaselineOffsetFromTop))
    }
    override var titleInk: NSColor? { name.textColor }
    /// The editor ends before the unread badge and the chevron, which stay where they are.
    override var titleEditMaxX: CGFloat { (badge.isHidden ? chevronFrame.minX : badge.frame.minX) - Metrics.space2 }
    private var renaming = false
    override func setTitleHidden(_ hidden: Bool) {
        renaming = hidden
        name.isHidden = hidden
        needsLayout = true
    }

    /// The Debug Settings look (`sidebar.groupHeader`, `sidebar.groupColors`, cx-7yywz) and line layout (its joined
    /// corner, `sidebar.groupLineLayout`); a change lays the header out and paints it again.
    private var look: (style: SidebarGroupHeaderStyle, themed: Bool) {
        let read = { _ = SidebarStyle.groupLineLayout; return (SidebarGroupHeaderStyle.tunable.value, SidebarGroupPalette.tunable.value == .theme) }
        guard !observesLook else { return read() }
        observesLook = true
        return withObservationTracking(read) { [weak self] in
            Task { @MainActor [weak self] in
                self?.observesLook = false
                self?.needsLayout = true
                self?.needsDisplay = true
            }
        }
    }

    /// One observation of the look is registered at a time.
    private var observesLook = false

    override func updateLayer() {
        performWithTheme {
            // The solid bar in the group's color (Lawrence 2026-10-11); hover
            // and a drop take tonal steps over it (the open editor lights its more button only).
            let tokens = themeTokens
            let look = look
            if look.style != .band { return paintQuiet(tokens, look) }
            let chip = tint.headerChip(themed: look.themed)
            var fill = chip.fill
            if isHovered { fill = tokens.hoverFill.composited(over: fill) }
            if isDropTarget { fill = tokens.pressedFill.composited(over: fill) }
            // One ink for every glyph on the bar (cx-qno.22): name, icon, pin,
            // chevron, + and more, chosen once on the bar's color; it holds
            // text contrast on every state above and the buttons' fills.
            let ink = chip.ink.nsColor.withAlphaComponent(archived ? SidebarStyle.archivedAlpha : 1)
            name.textColor = ink
            count.textColor = ink.withAlphaComponent(SidebarStyle.groupHeaderCountInkAlpha)
            glyph.symbolInk = ink
            pin.contentTintColor = ink
            chevron.contentTintColor = ink
            moreButton.tintOverride = ink
            addButton.tintOverride = ink
            paintMachine(ink: ink)
            // The bar carries the group's color: no dot over it (cx-rcby).
            dot.isHidden = true
            ChromeHover.paint(pill, fill.nsColor, animated: fadesNextFill)
            pill.borderWidth = 0
            paintFill(nil)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pill.opacity = archived ? Float(SidebarStyle.archivedAlpha) : 1 // dimmed with no fade (archiving-DESIGN.md)
            layer?.borderColor = Palette.focusRing.cgColor
            layer?.borderWidth = isKeyboardFocused ? Metrics.dividerThickness * 1.5 : 0
            layer?.cornerRadius = SidebarStyle.rowCornerRadius
            CATransaction.commit()
        }
    }

    /// The quieter headers (cx-7yywz): the name in primary ink (`tinted`: in the group's color) with
    /// the group's color as the dot where its line starts; `wash` adds a faint tint behind the name.
    /// Hover and a drop take the row's own fill; the open editor lights its more button only.
    private func paintQuiet(_ tokens: ThemeTokens, _ look: (style: SidebarGroupHeaderStyle, themed: Bool)) {
        let line = tint.lineRGB(themed: look.themed)
        let ink = (look.style == .tinted
            ? ThemeTokens.readable(line, over: tokens.sidebarBackground, minimum: ThemeTokens.minimumTextContrast).nsColor
            : tokens.textPrimary.nsColor).withAlphaComponent(archived ? SidebarStyle.archivedAlpha : 1)
        name.textColor = ink
        count.textColor = ink.withAlphaComponent(SidebarStyle.groupHeaderCountInkAlpha)
        glyph.symbolInk = ink
        let quiet = tokens.textSecondary.nsColor
        pin.contentTintColor = quiet
        chevron.contentTintColor = quiet
        moreButton.tintOverride = quiet
        addButton.tintOverride = quiet
        paintMachine(ink: quiet)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.isHidden = false
        dot.backgroundColor = line.nsColor.cgColor
        pill.opacity = archived ? Float(SidebarStyle.archivedAlpha) : 1
        dot.opacity = pill.opacity
        pill.borderWidth = 0
        layer?.borderColor = tokens.focusRing.nsColor.cgColor
        layer?.borderWidth = isKeyboardFocused ? Metrics.dividerThickness * 1.5 : 0
        layer?.cornerRadius = SidebarStyle.rowCornerRadius
        CATransaction.commit()
        guard look.style == .wash else {
            pill.backgroundColor = nil
            return paintFill(isDropTarget ? tokens.pressedFill.nsColor : isHovered ? tokens.hoverFill.nsColor : nil)
        }
        // The wash covers the row, so its states step over the wash, as the band's do.
        var fill = tint.headerWash(themed: look.themed)
        if isHovered { fill = tokens.hoverFill.composited(over: fill) }
        if isDropTarget { fill = tokens.pressedFill.composited(over: fill) }
        ChromeHover.paint(pill, fill.nsColor, animated: fadesNextFill)
        paintFill(nil)
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { (fadesNextHover, fadesNextActivity) = (false, false); CATransaction.commit() }

        // One full-width rounded bar (the Chrome tab group header) whose
        // radius, padding, type and glyphs scale with the row height
        // (the sidebar density: compact 24, comfortable 32 pt).
        // The bar fills the row (as tall as a workspace row); the type and glyphs keep their scale.
        // Type and glyphs follow a one-line row: an Expanded header is two lines tall, its name is not bigger.
        let barHeight = SidebarStyle.groupHeaderContentHeight(rowHeight: min(b.height, SidebarLayoutMetrics.standard.rowHeight))
        let pad = (barHeight * 0.62).rounded()
        // The name starts where ungrouped rows start (`SidebarStyle.horizontalInset`): an icon
        // on their icon column with the name on their text column, or the name alone on it.
        let lead = SidebarStyle.horizontalInset + railReach
        name.isHidden = renaming
        name.font = SidebarStyle.groupHeaderFont(barHeight: barHeight)
        count.font = SidebarStyle.groupHeaderCountFont(name: name.font ?? SidebarStyle.headerFont)
        // The chevron takes a trailing control's size (cx-fo2t), centered
        // on the trailing column every row's dot and spinner share (SidebarStyle+TrailingColumn).
        let chevronSide = min(b.height, SidebarStyle.trailingSlotSide)
        chevronFrame = SidebarStyle.trailingColumnFrame(rowWidth: b.width, centerY: b.height / 2, side: chevronSide)
        chevron.frame = chevronFrame
        let control = barHeight - Metrics.space1
        // The more button and the + center on the slots left of the chevron (`trailingSlotCenterX`), the lines a hovered
        // row's chevron and menu take, whatever the header's control size (Leo 2026-10-29: "MISALIGNED").
        // At most one slot wide, so neighbors never overlap (at a comfortable app density the control outgrows the pitch).
        let slotWidth = min(control, SidebarStyle.trailingSlotPitch)
        func slotFrame(_ slot: Int) -> NSRect {
            let x = max(pad, SidebarStyle.trailingSlotCenterX(rowWidth: b.width, slot: slot) - slotWidth / 2)
            return NSRect(x: x, y: (b.height - control) / 2, width: slotWidth, height: control)
        }
        moreButton.frame = slotFrame(1)
        // Lawrence 2026-10-11: the + and more show only on hover, keyboard
        // focus or while the editor is open. Hidden (not only clear): a click
        // there collapses the group, and VoiceOver uses the header's custom
        // actions. Lawrence 2026-10-20: no empty slots; the trailing items close
        // up, so the spinner sits by the chevron at rest and moves aside for
        // the buttons.
        let showsActions = (isHovered || isKeyboardFocused || isEditing) && !renaming
        // A loading spinner takes the column back when the hover ends: the controls clear at once, so it never draws
        // beside them as they fade (Leo 2026-10-28: "just don't show the spinner" while hovering).
        let loading = activity.showsGlyph && !activityEnding && !renaming
        let onColumn = loading && !showsActions
        // Lawrence 2026-10-19 (u2397): a hover fades them in and out (opacity
        // only); focus, the editor and Reduce Motion show them at once.
        let fades = fadesNextHover && !onColumn
        setHoverShown(moreButton, showsActions, fades: fades, token: .hoverReveal)
        moreButton.setAccessibilityElement(showsActions)
        addButton.frame = slotFrame(2)
        // An empty group offers its + too (user 17912, "empty workspace needs plus button"): New Workspace in Group
        // keeps a new group the editor would drop when it closes (`SidebarGroupFlow.performEditorItem`).
        let offersAdd = onAdd != nil
        setHoverShown(addButton, offersAdd && showsActions, fades: fades, token: .hoverReveal)
        addButton.setAccessibilityElement(offersAdd && showsActions)
        // Lawrence 2026-10-20: at rest a loading spinner takes the chevron's place, on the trailing
        // column every row's dot and spinner share (a296). Leo 2026-10-28: "If you're hovering over a
        // workspace or whatever, just don't show the spinner": a hover hides it at once and brings the
        // chevron back on the column, with the + and more left of it; never the spinner beside them.
        setHoverShown(chevron, !onColumn, fades: !onColumn && (fades || fadesNextActivity), token: .hoverReveal)
        var trailing = (showsActions ? (offersAdd ? addButton.frame.minX : moreButton.frame.minX) : chevronFrame.minX) - Metrics.space2
        trailing = layoutMachineTrailing(trailing, height: b.height, showsActions: showsActions)
        if badge.state.isUnread {
            badge.isHidden = false
            let w = badge.preferredWidth, h = SidebarStyle.badgeHeight
            badge.frame = NSRect(x: trailing - w, y: (b.height - h) / 2, width: w, height: h)
            trailing = badge.frame.minX - Metrics.space2
        } else {
            badge.isHidden = true
        }
        // The spinner fades and its slot collapses as loading stops (grows as it starts): the
        // items around it close up with no hole (`setHoverSlotShown`, instant under Reduce Motion).
        let ind = SidebarStyle.indicatorSize
        let slotFrame = SidebarStyle.trailingColumnFrame(rowWidth: b.width, centerY: b.height / 2, side: ind)
        setHoverSlotShown(activitySlot, onColumn, frame: slotFrame, fades: (fadesNextActivity || fades) && !showsActions) { [weak self] in
            guard let self, self.activityEnding else { return }
            self.activityEnding = false
            self.activity.configure(.idle)
        }
        let glyphSide = min(SidebarStyle.iconBox, barHeight)
        glyph.isHidden = !hasIcon || leadsWithMachineMark
        // A pinned group's pin leads the bar, its ink centered on the rows' icon column, and its icon and name take the
        // one text column after it, as a pinned workspace row's do (Lawrence 2026-10-28, "home and pinned are not
        // aligned"; Leo 2026-10-28, "the alignment").
        let pinSide = SidebarStyle.leadingGlyphSide
        pin.isHidden = !pinned
        let pinInk = pin.image.flatMap { SidebarGlyphInk.shared.box(of: $0, glyph: SidebarItemRowView.pinGlyph) }
        let scale = window?.backingScaleFactor ?? 2
        let pinX = SidebarStyle.iconColumnCenterX(leading: lead) - (pinInk?.midX ?? pinSide / 2)
        pin.frame = NSRect(x: (pinX * scale).rounded() / scale, y: (b.height - pinSide) / 2, width: pinSide, height: pinSide)
        let iconLead = pinned ? SidebarStyle.leadingTextX(leading: lead) : lead
        glyph.frame = NSRect(x: iconLead, y: (b.height - glyphSide) / 2, width: glyphSide, height: glyphSide)
        if leadsWithMachineMark {
            machineMark.frame = glyph.frame
        }
        // The label's frame sits its text inset left of the column, as a workspace title's does.
        let nx = (hasIcon || leadsWithMachineMark ? glyph.frame.maxX + Metrics.space3 : iconLead) - Metrics.space1
        var countWidth = count.stringValue.isEmpty || renaming ? 0 : Self.drawnWidth(count)
        // A sidebar too narrow for the count drops it rather than drawing it over the trailing controls.
        if nx + countWidth + Metrics.space2 > trailing { countWidth = 0 }
        let countRoom = countWidth > 0 ? countWidth + Metrics.space2 : 0
        let nameWidth = min(titleIntrinsicWidth, max(0, trailing - countRoom - nx))
        let nh = ceil(name.intrinsicContentSize.height)
        name.frame = NSRect(x: nx, y: (b.height - nh) / 2, width: nameWidth, height: nh)
        count.isHidden = countWidth == 0
        count.frame = NSRect(x: name.frame.maxX + Metrics.space2, y: (b.height - nh) / 2, width: countWidth, height: nh)
        // The name and the color line only: no bar (cx-7yywz).
        pill.isHidden = look.style == .line || look.style == .tinted
        // The cx-rcby chip: one full-width rounded bar, the row's full height like a workspace row's fill.
        pill.frame = NSRect(x: 0, y: 0, width: b.width, height: b.height)
        pill.cornerRadius = SidebarStyle.rowCornerRadius // one radius with the pinned and workspace rows
        pill.maskedCorners = SidebarGroupLine.barCorners(open: !collapsed, flipped: pill.contentsAreFlipped()) // joined: an L
        // The quiet styles' dot sits where the members' line starts (`railReach` less the layout's overhang, `groupLineX`).
        let dotSide = SidebarStyle.groupDotSize
        dot.frame = CGRect(x: max(0, railReach - SidebarStyle.groupRailReach), y: (b.height - dotSide) / 2, width: dotSide, height: dotSide)
        dot.cornerRadius = dotSide / 2
        // The members' line starts under this bar: one layer per group
        // under the rows (SidebarListView+GroupLines, cx-qno.17).
        needsDisplay = true
    }

    override func hoverChanged() {
        super.hoverChanged()
        // The fill still shows at once on entry; the + and more fade both ways (u2397).
        fadesNextHover = true
        needsLayout = true
    }
}

// MARK: - Remote group (user 2026-10-31, Chief msg 19277: "it needs to look like a group in the sidebar")

extension GroupHeaderRowView {
    /// The remote group's machine mark leads the name, in the icon's place (``SidebarHostGroupLook/leadingMark``).
    var leadsWithMachineMark: Bool { machineIsShown && hostLook == .leadingMark }

    private var machineIsShown: Bool { !machineMark.isHidden || !machineDot.isHidden || !machineWords.isHidden }

    /// Whether this header is a remote group's (tests, the gallery).
    var showsMachine: Bool { machineIsShown }
    /// The status the remote group's dot shows (tests).
    var debugMachineTone: SectionHeaderRowView.StatusTone? { machineDot.isHidden ? nil : machineTone }

    fileprivate func configureMachine(_ machine: SidebarMachine?) {
        guard let machine else {
            self.machine = nil
            machineTone = nil
            machineMark.isHidden = true
            machineDot.isHidden = true
            machineWords.isHidden = true
            return
        }
        self.machine = machine
        let tone = SectionHeaderRowView.tone(machine, hostGroup: true)
        machineTone = tone
        let look = hostLook
        let symbol: IconName = machine.kind == .cloud ? .cloud : .machineRemote
        machineMark.image = NSImage.icon(symbol, size: SidebarStyle.leadingGlyphSide)
        machineMark.isHidden = look == .dotOnly
        // The quiet look keeps the dot for a machine that needs the person (or is on its way).
        let quiet = look == .markQuietWhenConnected && (tone == .success || tone == nil)
        machineDot.isHidden = tone == nil || look == .markAndWords || quiet
        machineWords.stringValue = SectionHeaderRowView.statusWords(machine.status)
        machineWords.isHidden = look != .markAndWords
        machineMark.setAccessibilityElement(false)
        themedToolTip = machine.detail.map { "\(SectionHeaderRowView.statusWords(machine.status)): \($0)" }
            ?? SectionHeaderRowView.statusWords(machine.status)
    }

    // theme-scoped: called only inside performWithTheme
    fileprivate func paintMachine(ink: NSColor) {
        machineMark.contentTintColor = ink
        machineWords.textColor = ink.withAlphaComponent(SidebarStyle.groupHeaderCountInkAlpha)
        let color: NSColor? = switch machineTone {
        case .success: Palette.success
        case .attention: Palette.attention
        case .danger: Palette.danger
        case .quiet, .working, nil: ink.withAlphaComponent(0.55)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        machineDot.backgroundColor = color?.cgColor
        // A ring in the bar's ink keeps the dot apart from any bar color (green on green, red on red).
        machineDot.borderColor = ink.withAlphaComponent(0.35).cgColor
        machineDot.borderWidth = 1
        CATransaction.commit()
    }

    /// Lays out the trailing machine mark, words and dot right to left from `trailing`, before the badge and
    /// the name; returns the x left of them. They stay while the + and more show (a remote group says where it
    /// runs also under the pointer).
    fileprivate func layoutMachineTrailing(_ trailing: CGFloat, height: CGFloat, showsActions: Bool) -> CGFloat {
        guard machine != nil else { return trailing }
        var x = trailing
        let dotSide = SidebarStyle.dotSize
        if !machineDot.isHidden {
            machineDot.frame = CGRect(x: x - dotSide, y: (height - dotSide) / 2, width: dotSide, height: dotSide)
            machineDot.cornerRadius = dotSide / 2
            x = machineDot.frame.minX - Metrics.space2
        }
        if !machineWords.isHidden {
            let w = ceil(machineWords.intrinsicContentSize.width), h = ceil(machineWords.intrinsicContentSize.height)
            machineWords.font = SidebarStyle.groupHeaderCountFont(name: name.font ?? SidebarStyle.headerFont)
            machineWords.frame = NSRect(x: x - w, y: (height - h) / 2, width: w, height: h)
            x = machineWords.frame.minX - Metrics.space1
        }
        if !machineMark.isHidden, !leadsWithMachineMark {
            let side = SidebarStyle.leadingGlyphSide
            machineMark.frame = NSRect(x: x - side, y: (height - side) / 2, width: side, height: side)
            x = machineMark.frame.minX - Metrics.space2
        }
        return x
    }
}

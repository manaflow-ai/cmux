import AppKit
import CmuxNextDesign
import CmuxNextIcons
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
/// open, in slots that are always reserved, so nothing moves. Hover and a
/// drop take tonal steps over the bar's color. Type and glyphs scale with the row height
/// (the sidebar density setting). A collapsed group shows its member count
/// after the name (cg-design-judge 2026-10-14), and its members' activity and
/// unread total. Minimal mode keeps the bar, only shorter: a hairline header
/// read as a stray line, not a group (Lawrence 2026-10-18, over #19936). The name and the more button open
/// the group editor (cx-rcby, Lawrence 2026-10-08); a right-click shows the
/// group's full menu (cx-a9h6); the chevron and the rest of the row collapse.
final class GroupHeaderRowView: SidebarRowView {
    private let name = SidebarRowView.label(font: SidebarStyle.headerFont)
    /// A collapsed group's member count, after the name.
    private let count = SidebarRowView.label(font: SidebarStyle.headerFont)
    private let chevron = NSImageView()
    private let activity = StatusIndicatorView()
    private let badge = UnreadBadgeView()
    private let pin = NSImageView()
    /// The group's icon inside its chip, before the name (`workspace-group-icon-v1`).
    let glyph = SidebarIconView()
    private let pill = CALayer()
    /// The group's color as a dot on its line (cx-25az, Leo 2026-10-10: no full
    /// pastel fill): the line starts under it and runs to the last member.
    private let dot = CALayer()
    /// The more button (the pack's three-dot action.more): the group editor, as a click on the
    /// name (cx-rcby, Lawrence 2026-10-08); its More Group Actions row has the full menu.
    let moreButton = SidebarIconButton(icon: .actionMore, pointSize: { Metrics.smallIconSize - Metrics.space1 },
                                       label: GroupEditorStrings.more)
    /// The add button (+): a new workspace at the end of the group (cmuxterm-hq#1829,
    /// the Edge group header). Shows with the more button.
    let addButton = SidebarIconButton(icon: .actionAdd, pointSize: { Metrics.smallIconSize - Metrics.space1 },
                                      label: GroupEditorStrings.newWorkspace)
    private var pinned = false
    private var hasIcon = false
    /// No members: the + is not offered (the editor's New Workspace in Group
    /// is), so a click on it can never race the editor closing on a new,
    /// still empty group that then goes.
    private var isEmpty = false
    private var tint: GroupTint = .palette(.grey)
    private var collapsed = false
    private var chevronFrame: CGRect = .zero
    private var chevronIcon: IconName = .disclosureExpanded
    var isDropTarget = false { didSet { if isDropTarget != oldValue { needsDisplay = true } } }
    /// Arrow keys stopped here (`SidebarListView+GroupKeys`): a focus ring, not a selection.
    var isKeyboardFocused = false { didSet { if isKeyboardFocused != oldValue { needsLayout = true; needsDisplay = true } } }
    /// The group editor is open for this group.
    var isEditing = false { didSet { if isEditing != oldValue { needsLayout = true; needsDisplay = true } } }
    /// Shows the group's full menu: VoiceOver's More Group Actions (the editor's last row).
    var onMore: (() -> Void)?
    /// Opens the group editor (name, color and actions): the more button and VoiceOver's Edit action.
    var onEdit: (() -> Void)?
    var onAdd: (() -> Void)?

    override var interactiveSubviews: [NSView] { [addButton, moreButton] }

    required init(key: SidebarRowKey) {
        super.init(key: key)
        layer?.addSublayer(pill)
        layer?.addSublayer(dot)
        pill.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
        dot.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
        [glyph, name, count, pin, chevron, activity, badge, addButton, moreButton].forEach(addSubview)
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
                guard let self, let onAdd = self.onAdd, !self.isEmpty else { return false }
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
        onMore = nil
        onEdit = nil
        onAdd = nil
    }

    private struct Content: Hashable {
        var group: SidebarGroup
        var childCount: Int
        var collapsed: Bool
        var fontSize: CGFloat
    }

    func configure(_ group: SidebarGroup, row: SidebarRow, animated: Bool) {
        let content = Content(group: group, childCount: row.childCount, collapsed: row.isCollapsed, fontSize: SidebarStyle.headerFont.pointSize)
        guard needsConfigure(content) else { return }
        tint = group.tint
        isEmpty = group.workspaces.isEmpty && group.items.isEmpty
        name.stringValue = group.name
        pinned = group.isPinned
        hasIcon = group.icon != nil
        glyph.configure(icon: group.icon)
        pin.image = pinned ? NSImage.icon(.statePinned, size: Metrics.smallIconSize) : nil
        collapsed = row.isCollapsed
        count.stringValue = collapsed && row.childCount > 0 ? "\(row.childCount)" : ""
        chevronIcon = Self.disclosureIcon(collapsed: collapsed)
        chevron.image = NSImage.icon(chevronIcon, size: .iconRowSize(forLabelPointSize: Metrics.smallIconSize - Metrics.space2))
        activity.configure(collapsed ? group.aggregateActivity : .idle)
        let unread = group.unreadTotal
        badge.configure(collapsed && unread > 0 ? .count(unread) : .none)
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel("\(group.name), \(Strings.groupCount(row.childCount))")
        setAccessibilityHelp(collapsed ? GroupEditorStrings.expand : GroupEditorStrings.collapse)
        setAccessibilityExpanded(!collapsed)
        needsLayout = true
        needsDisplay = true
    }

    /// One disclosure convention with workspace rows (cx-fo2t, Finder and
    /// Edge): open points down, collapsed points right.
    private static func disclosureIcon(collapsed: Bool) -> IconName {
        collapsed ? .disclosureCollapsed : .disclosureExpanded
    }

    /// A state fill on the bar (hover, open editor, drop); the bar itself always shows.
    override var debugFill: Bool { super.debugFill || isHovered || isEditing || isDropTarget }
    override var debugDisclosure: (icon: String, frame: CGRect, shown: Bool)? { (chevronIcon.rawValue, chevron.frame, !chevron.isHidden) }

    override var titleFrame: NSRect { name.frame }
    /// The member count a collapsed header shows, nil when it shows none.
    var countText: String? { count.isHidden || count.stringValue.isEmpty ? nil : count.stringValue }
    /// The count's label, laid out (`SidebarGroupChromeLookTests`).
    var countLabel: ChromeLabel { count }
    /// The one ink every glyph on the header takes.
    var ink: NSColor? { name.textColor }
    /// The group chip (`GroupLabelBandTests`): a click here opens the editor.
    var labelFrame: NSRect { pill.frame }
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
    /// The group's name and icon: a click here opens the editor; the rest
    /// of the bar and the chevron collapse (the Chrome header toggles).
    var nameHitFrame: NSRect {
        let start = hasIcon ? glyph.frame.minX : name.frame.minX
        return NSRect(x: start - Metrics.space2, y: 0, width: name.frame.maxX - start + 2 * Metrics.space2, height: bounds.height)
    }
    override var titleFont: NSFont { name.font ?? SidebarStyle.headerFont }
    private var renaming = false
    override func setTitleHidden(_ hidden: Bool) {
        renaming = hidden
        name.isHidden = hidden
        needsLayout = true
    }

    override func updateLayer() {
        performWithTheme {
            // The solid bar in the group's color (Lawrence 2026-10-11); hover,
            // the open editor and a drop take tonal steps over it.
            let tokens = themeTokens
            let chip = tint.headerChip
            var fill = chip.fill
            if isHovered || isEditing { fill = tokens.hoverFill.composited(over: fill) }
            if isDropTarget { fill = tokens.pressedFill.composited(over: fill) }
            // One ink for every glyph on the bar (cx-qno.22): name, icon, pin,
            // chevron, + and more, chosen once on the bar's color; it holds
            // text contrast on every state above and the buttons' fills.
            let ink = chip.ink.nsColor
            name.textColor = ink
            count.textColor = ink
            glyph.symbolInk = ink
            pin.contentTintColor = ink
            chevron.contentTintColor = ink
            moreButton.tintOverride = ink
            addButton.tintOverride = ink
            // The bar carries the group's color: no dot over it (cx-rcby).
            dot.isHidden = true
            ChromeHover.paint(pill, fill.nsColor, animated: fadesNextFill)
            pill.borderWidth = 0
            paintFill(nil)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.borderColor = Palette.focusRing.cgColor
            layer?.borderWidth = isKeyboardFocused ? Metrics.dividerThickness * 1.5 : 0
            layer?.cornerRadius = SidebarStyle.rowCornerRadius
            CATransaction.commit()
        }
    }

    /// The chevron and the space around it: a click here collapses or expands.
    var disclosureFrame: NSRect { chevronFrame.insetBy(dx: -Metrics.space1, dy: -Metrics.space2) }

    override func layout() {
        super.layout()
        let b = layoutBounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // One full-width rounded bar (the Chrome tab group header) whose
        // radius, padding, type and glyphs scale with the row height
        // (the sidebar density: compact 24, comfortable 32 pt).
        let barHeight = SidebarStyle.groupHeaderBarHeight(rowHeight: b.height)
        let pad = (barHeight * 0.62).rounded()
        // The name starts where ungrouped rows start (`SidebarStyle.horizontalInset`): an icon
        // on their icon column with the name on their text column, or the name alone on it.
        let lead = SidebarStyle.horizontalInset
        name.isHidden = renaming
        name.font = SidebarStyle.groupHeaderFont(barHeight: barHeight)
        count.font = name.font
        // The chevron sits where a workspace row's disclosure does, at its size (cx-fo2t).
        let chevronSide = min(b.height, SidebarStyle.controlSize)
        chevronFrame = CGRect(x: b.width - Metrics.space3 - chevronSide, y: (b.height - chevronSide) / 2, width: chevronSide, height: chevronSide)
        chevron.frame = chevronFrame
        let control = barHeight - Metrics.space1
        // The more button keeps a stable slot left of the chevron.
        moreButton.frame = NSRect(x: max(pad, chevronFrame.minX - Metrics.space1 - control), y: (b.height - control) / 2, width: control, height: control)
        // Lawrence 2026-10-11: the + and more show only on hover, keyboard
        // focus or while the editor is open. Their slots are always reserved,
        // so the name, badge and chevron never move. Hidden (not only clear):
        // a click there collapses the group, and VoiceOver uses the header's
        // custom actions.
        let showsActions = (isHovered || isKeyboardFocused || isEditing) && !renaming
        moreButton.isHidden = !showsActions
        moreButton.alphaValue = 1
        moreButton.setAccessibilityElement(showsActions)
        addButton.frame = moreButton.frame.offsetBy(dx: -(control + Metrics.space1), dy: 0)
        addButton.frame.origin.x = max(pad, addButton.frame.minX)
        let offersAdd = onAdd != nil && !isEmpty
        addButton.isHidden = !offersAdd || !showsActions
        addButton.setAccessibilityElement(offersAdd && showsActions)
        // The badge and activity keep their place whether or not the buttons show.
        var trailing = (offersAdd ? addButton.frame.minX : moreButton.frame.minX) - Metrics.space2
        if badge.state.isUnread {
            badge.isHidden = false
            let w = badge.preferredWidth, h = SidebarStyle.badgeHeight
            badge.frame = NSRect(x: trailing - w, y: (b.height - h) / 2, width: w, height: h)
            trailing = badge.frame.minX - Metrics.space2
        } else {
            badge.isHidden = true
        }
        if activity.showsGlyph {
            let ind = SidebarStyle.indicatorSize
            activity.frame = NSRect(x: trailing - ind, y: (b.height - ind) / 2, width: ind, height: ind)
            trailing -= ind + Metrics.space2
        }
        let glyphSide = min(SidebarStyle.iconBox, barHeight)
        glyph.isHidden = !hasIcon
        glyph.frame = NSRect(x: lead, y: (b.height - glyphSide) / 2, width: glyphSide, height: glyphSide)
        // The label's frame sits its text inset left of the column, as a workspace title's does.
        let nx = (hasIcon ? glyph.frame.maxX + Metrics.space3 : lead) - Metrics.space1
        let pinSide = Metrics.smallIconSize
        let pinRoom = pinned ? pinSide + Metrics.space2 : 0
        var countWidth = count.stringValue.isEmpty || renaming ? 0 : Self.drawnWidth(count)
        // A sidebar too narrow for the count drops it rather than drawing it over the trailing controls.
        if nx + pinRoom + countWidth + Metrics.space2 > trailing { countWidth = 0 }
        let countRoom = countWidth > 0 ? countWidth + Metrics.space2 : 0
        let nameWidth = min(titleIntrinsicWidth, max(0, trailing - pinRoom - countRoom - nx))
        let nh = ceil(name.intrinsicContentSize.height)
        name.frame = NSRect(x: nx, y: (b.height - nh) / 2, width: nameWidth, height: nh)
        pin.isHidden = !pinned
        pin.frame = NSRect(x: name.frame.maxX + Metrics.space2, y: (b.height - pinSide) / 2, width: pinSide, height: pinSide)
        count.isHidden = countWidth == 0
        count.frame = NSRect(x: (pinned ? pin.frame.maxX : name.frame.maxX) + Metrics.space2, y: (b.height - nh) / 2, width: countWidth, height: nh)
        pill.isHidden = renaming
        // The cx-rcby chip: one full-width rounded bar, a little inset top and bottom.
        pill.frame = NSRect(x: 0, y: (b.height - barHeight) / 2, width: b.width, height: barHeight)
        pill.cornerRadius = (barHeight * 0.23).rounded()
        // The dot is centred on the group line's x, where the line starts (SidebarListView+GroupLines).
        let dotSide = SidebarStyle.groupDotSize
        dot.frame = CGRect(x: SidebarStyle.groupBarX + SidebarStyle.groupBarWidth / 2 - dotSide / 2, y: (b.height - dotSide) / 2,
                           width: dotSide, height: dotSide)
        dot.cornerRadius = dotSide / 2
        // The members' line starts under this bar: one layer per group
        // under the rows (SidebarListView+GroupLines, cx-qno.17).
        needsDisplay = true
    }

    override func hoverChanged() {
        super.hoverChanged()
        needsLayout = true
    }
}

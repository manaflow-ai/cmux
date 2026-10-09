import AppKit
import CmuxNextDesign
import CmuxNextIcons
import QuartzCore

/// Group header as a Chrome tab group chip, in cmux's own style (cx-rcby,
/// Lawrence 2026-10-08: "make groups like this"): one compact pill with the
/// group's icon and name, a more (⋮) button that shows on hover, and the
/// collapse chevron at its end. The pill is the group's theme color washed
/// into the sidebar (`GroupColor.themedChipFill`; neutral for none). No
/// member count: a collapsed group shows its members' activity and unread
/// total after the pill. The name and the more button open the group
/// editor; the chevron and the rest of the row collapse.
final class GroupHeaderRowView: SidebarRowView {
    private let name = SidebarRowView.label(font: SidebarStyle.headerFont)
    private let chevron = NSImageView()
    private let activity = StatusIndicatorView()
    private let badge = UnreadBadgeView()
    private let pin = NSImageView()
    /// The group's icon inside its chip, before the name (`workspace-group-icon-v1`).
    let glyph = SidebarIconView()
    private let pill = CALayer()
    /// The more button (⋮): the group editor. Shows on hover and while the editor is open.
    let moreButton = SidebarIconButton(symbol: "ellipsis", pointSize: { Metrics.smallIconSize - Metrics.space1 }, weight: .bold,
                                       label: GroupEditorStrings.more)
    private var pinned = false
    private var hasIcon = false
    private var color: GroupColor = .grey
    private var collapsed = false
    private var chevronFrame: CGRect = .zero
    var isDropTarget = false { didSet { if isDropTarget != oldValue { needsDisplay = true } } }
    /// Arrow keys stopped here (`SidebarListView+GroupKeys`): a focus ring, not a selection.
    var isKeyboardFocused = false { didSet { if isKeyboardFocused != oldValue { needsDisplay = true } } }
    /// The group editor is open for this group: the chip stays in its hover look.
    var isEditing = false { didSet { if isEditing != oldValue { needsLayout = true; needsDisplay = true } } }
    var onMore: (() -> Void)?

    override var interactiveSubviews: [NSView] { [moreButton] }

    required init(key: SidebarRowKey) {
        super.init(key: key)
        layer?.addSublayer(pill)
        pill.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
        glyph.drawsUncoloredSymbolAsText = true
        // The more glyph stands upright (⋮), like the Chrome chip's.
        moreButton.frameCenterRotation = 90
        [glyph, name, pin, chevron, activity, badge, moreButton].forEach(addSubview)
        moreButton.onPress = { [weak self] in self?.onMore?() }
    }

    override func prepareForReuse(key: SidebarRowKey) {
        super.prepareForReuse(key: key)
        isDropTarget = false
        isKeyboardFocused = false
        isEditing = false
        collapsed = false
        onMore = nil
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
        color = group.color
        name.stringValue = group.name
        name.font = SidebarStyle.headerFont
        pinned = group.isPinned
        hasIcon = group.icon != nil
        glyph.configure(icon: group.icon)
        pin.image = pinned ? NSImage.icon(.statePinned, size: Metrics.smallIconSize) : nil
        collapsed = row.isCollapsed
        chevron.image = Self.chevronImage(collapsed: collapsed)
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

    private static func chevronImage(collapsed: Bool) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: Metrics.smallIconSize - Metrics.space2, weight: .bold)
        return NSImage(systemSymbolName: collapsed ? "chevron.down" : "chevron.up", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    override var titleFrame: NSRect { name.frame }
    /// The group chip (`GroupLabelBandTests`): a click here opens the editor.
    var labelFrame: NSRect { pill.frame }
    /// The width the name needs to draw whole (`GroupLabelBandTests`).
    var titleIntrinsicWidth: CGFloat {
        let font = name.font ?? SidebarStyle.headerFont
        let text = ceil((name.stringValue as NSString).size(withAttributes: [.font: font]).width)
        return max(ceil(name.intrinsicContentSize.width), text + 2 * Metrics.space2)
    }
    var labelFill: CGColor? { pill.isHidden ? nil : pill.backgroundColor }
    override var titleFont: NSFont { SidebarStyle.headerFont }
    private var renaming = false
    override func setTitleHidden(_ hidden: Bool) {
        renaming = hidden
        name.isHidden = hidden
    }

    /// Whether the more button shows: on hover, and while the editor is open.
    private var showsMore: Bool { isHovered || isEditing }

    override func updateLayer() {
        performWithTheme {
            name.textColor = Palette.textPrimary
            pin.contentTintColor = Palette.textTertiary
            chevron.contentTintColor = Palette.textSecondary
            moreButton.contentTintColor = Palette.textSecondary
            var fill = color.themedChipFill
            if isHovered || isEditing { fill = fill.blended(withFraction: 0.08, of: Palette.textPrimary) ?? fill }
            if isDropTarget { fill = fill.blended(withFraction: 0.16, of: Palette.textPrimary) ?? fill }
            pill.backgroundColor = fill.cgColor
            if isDropTarget {
                pill.borderColor = (color.themed ?? Palette.focusRing).cgColor
                pill.borderWidth = Metrics.dividerThickness * 1.5
                paintFill(color.themed?.withAlphaComponent(0.12) ?? Palette.selectionFill)
            } else {
                pill.borderWidth = 0
                // A collapsed group that holds the selected workspace paints the selection fill.
                paintFill(isSelected ? Palette.selectionFill : nil)
            }
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

        name.isHidden = renaming
        var trailing = b.width - Metrics.space3
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
        let pinSide = Metrics.smallIconSize
        let pinRoom = pinned ? pinSide + Metrics.space2 : 0

        // The chip: [icon] name [⋮] chevron, a capsule.
        let chipX = SidebarStyle.groupChipLeading
        let chipHeight = SidebarStyle.groupChipHeight(rowHeight: b.height)
        let chipY = (b.height - chipHeight) / 2
        let pad = Metrics.space3
        let glyphSide = min(SidebarStyle.iconBox, chipHeight)
        glyph.isHidden = !hasIcon
        glyph.frame = NSRect(x: chipX + pad - Metrics.space1, y: (b.height - glyphSide) / 2, width: glyphSide, height: glyphSide)
        let nx = chipX + pad + (hasIcon ? glyphSide : 0)
        let chevronSide = Metrics.smallIconSize
        let control = chipHeight - Metrics.space1
        // The more button's slot is kept whether or not it shows, so the
        // name never re-truncates on hover (SidebarHoverStabilityTests).
        let tail = Metrics.space1 + control + chevronSide + pad
        let nameWidth = min(titleIntrinsicWidth, max(0, trailing - pinRoom - nx - tail))
        let nh = ceil(name.intrinsicContentSize.height)
        name.frame = NSRect(x: nx, y: (b.height - nh) / 2, width: nameWidth, height: nh)
        let moreX = nx + nameWidth + Metrics.space1
        moreButton.frame = NSRect(x: moreX, y: (b.height - control) / 2, width: control, height: control)
        moreButton.isHidden = !showsMore
        // At rest the chip ends after the chevron; the more slot shows inside it on hover.
        let chevronX = showsMore ? moreX + control : nx + nameWidth + Metrics.space1
        chevronFrame = CGRect(x: chevronX, y: (b.height - chevronSide) / 2, width: chevronSide, height: chevronSide)
        chevron.frame = chevronFrame
        pill.isHidden = renaming
        pill.frame = NSRect(x: chipX, y: chipY, width: chevronFrame.maxX + pad - chipX, height: chipHeight)
        pill.cornerRadius = chipHeight / 2
        pin.isHidden = !pinned
        pin.frame = NSRect(x: pill.frame.maxX + Metrics.space2, y: (b.height - pinSide) / 2, width: pinSide, height: pinSide)
        needsDisplay = true
    }

    override func hoverChanged() {
        super.hoverChanged()
        needsLayout = true
    }

    /// A new group's chip arrives once: it fades and scales up from the
    /// chip's leading edge (Reduce Motion: no scale, the row's fade only).
    func playAppear() {
        guard Motion.animatesMovement else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.86
        scale.toValue = 1
        scale.duration = Motion.duration(MotionSpring.appear)
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pill.add(scale, forKey: "cmux.groupAppear")
    }
}

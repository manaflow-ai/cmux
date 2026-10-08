import AppKit
import CmuxNextDesign
import CmuxNextIcons
import QuartzCore

/// Group header, option B "Color label and band" (Lawrence 2026-10-07; spec
/// WORKSPACE-GROUPS-OPTION-A amendment 1): the disclosure caret leads at the
/// leading inset (S1, Dia-style hover fill on the whole row), then the name
/// in a colored label, the tab-group chip (GroupColor.fill; a neutral chip
/// without a color). The member count shows at rest and gives its slot to
/// the + / pencil buttons on hover. A collapsed group also surfaces its
/// children's activity and unread total.
final class GroupHeaderRowView: SidebarRowView {
    private let dot = CAShapeLayer()
    private let name = SidebarRowView.label(font: SidebarStyle.headerFont)
    private let count = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    private let chevron = NSImageView()
    private let activity = StatusIndicatorView()
    private let badge = UnreadBadgeView()
    private let pin = NSImageView()
    /// The group's icon inside its label (`workspace-group-icon-v1`); not drawn yet.
    let glyph = SidebarIconView()
    private let pill = CALayer()
    let addButton = SidebarIconButton(symbol: "plus", pointSize: { Metrics.smallIconSize - Metrics.space1 }, weight: .semibold, label: Strings.newWorkspace)
    let editButton = SidebarIconButton(symbol: "pencil", pointSize: { Metrics.smallIconSize - Metrics.space1 }, weight: .semibold, label: Strings.rename)
    private var pinned = false
    private var color: GroupColor = .grey
    private var collapsed = false
    private var chevronFrame: CGRect = .zero
    var isDropTarget = false { didSet { if isDropTarget != oldValue { needsDisplay = true } } }
    /// Arrow keys stopped here (`SidebarListView+GroupKeys`): a focus ring, not a selection.
    var isKeyboardFocused = false { didSet { if isKeyboardFocused != oldValue { needsDisplay = true } } }
    var onAdd: (() -> Void)?
    var onEdit: (() -> Void)?

    override var interactiveSubviews: [NSView] { [addButton, editButton] }

    required init(key: SidebarRowKey) {
        super.init(key: key)
        layer?.addSublayer(pill)
        layer?.addSublayer(dot)
        count.alignment = .right
        [name, pin, count, chevron, activity, badge, addButton, editButton].forEach(addSubview)
        addButton.onPress = { [weak self] in self?.onAdd?() }
        editButton.onPress = { [weak self] in self?.onEdit?() }
    }

    override func prepareForReuse(key: SidebarRowKey) {
        super.prepareForReuse(key: key)
        isDropTarget = false
        isKeyboardFocused = false
        collapsed = false
        onAdd = nil
        onEdit = nil
    }

    private struct Content: Hashable {
        var group: SidebarGroup
        var childCount: Int
        var collapsed: Bool
        var fontSize: CGFloat
        var dotSize: CGFloat
    }

    func configure(_ group: SidebarGroup, row: SidebarRow, animated: Bool) {
        let content = Content(
            group: group, childCount: row.childCount, collapsed: row.isCollapsed,
            fontSize: SidebarStyle.headerFont.pointSize, dotSize: SidebarStyle.dotSize
        )
        guard needsConfigure(content) else { return }
        color = group.color
        name.stringValue = group.name
        name.font = SidebarStyle.headerFont
        count.font = SidebarStyle.subtitleFont
        count.stringValue = "\(row.childCount)"
        pinned = group.isPinned
        pin.image = pinned ? NSImage.icon(.statePinned, size: Metrics.smallIconSize) : nil
        collapsed = row.isCollapsed
        chevron.image = SidebarStyle.chevron(collapsed: collapsed)
        activity.configure(collapsed ? group.aggregateActivity : .idle)
        let unread = group.unreadTotal
        badge.configure(collapsed && unread > 0 ? .count(unread) : .none)
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel("\(group.name), \(Strings.groupCount(row.childCount))")
        setAccessibilityExpanded(!collapsed)
        needsLayout = true
        needsDisplay = true
    }

    override var titleFrame: NSRect { name.frame }
    /// The name's colored label (`GroupLabelBandTests`).
    var labelFrame: NSRect { pill.frame }
    /// The width the name needs to draw whole (`GroupLabelBandTests`).
    var titleIntrinsicWidth: CGFloat {
        // The label's own measure plus the cell's text inset on both sides,
        // measured with the header font it draws in (the live capture cut
        // "Frontend" to "Fronte…" at the bare measured width).
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

    override func updateLayer() {
        performWithTheme {
            name.textColor = Palette.textPrimary
            count.textColor = Palette.textTertiary
            pin.contentTintColor = Palette.textTertiary
            chevron.contentTintColor = isHovered ? Palette.textSecondary : Palette.textTertiary
            let tint = SidebarStyle.color(color)
            // The label: the tab-group chip fill, a neutral chip without a
            // color; hover darkens it like a tab-group chip.
            var fill = color == .grey ? Palette.badgeFill : color.fill
            if isHovered { fill = fill.blended(withFraction: 0.08, of: Palette.textPrimary) ?? fill }
            if isDropTarget { fill = fill.blended(withFraction: 0.16, of: Palette.textPrimary) ?? fill }
            pill.backgroundColor = fill.cgColor
            // Fills only: a drop onto the group tints the row in its color; a
            // selected group (or the collapsed group that holds the selected
            // workspace) paints the selection fill.
            if isDropTarget {
                paintFill(color == .grey ? Palette.selectionFill : tint.withAlphaComponent(0.16))
                pill.borderColor = (color == .grey ? Palette.focusRing : tint).cgColor
                pill.borderWidth = Metrics.dividerThickness * 1.5
            } else if isSelected {
                pill.borderWidth = 0
                paintFill(Palette.selectionFill)
            } else {
                pill.borderWidth = 0
                paintFill(isHovered ? Palette.hoverFill : nil)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.borderColor = Palette.focusRing.cgColor
            layer?.borderWidth = isKeyboardFocused ? Metrics.dividerThickness * 1.5 : 0
            layer?.cornerRadius = SidebarStyle.rowCornerRadius
            // The label carries the color; the dot layer stays for reuse.
            dot.isHidden = true
            dot.fillColor = collapsed ? nil : tint.cgColor
            dot.strokeColor = tint.cgColor
            dot.lineWidth = collapsed ? Metrics.dividerThickness * 1.5 : 0
            CATransaction.commit()
        }
    }

    /// The disclosure caret and the inset before it: a click here toggles
    /// immediately (a click on the name waits for a double click).
    var disclosureFrame: NSRect { NSRect(x: 0, y: 0, width: chevronFrame.maxX + Metrics.space1 / 2, height: bounds.height) }

    override func layout() {
        super.layout()
        let b = layoutBounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let inset = Metrics.dividerThickness
        let chevronSide = Metrics.smallIconSize

        name.isHidden = renaming

        var trailing = b.width - Metrics.space3
        let control = SidebarStyle.controlSize
        // Hover controls keep their slots, so the name never re-truncates on hover.
        addButton.isHidden = !isHovered
        editButton.isHidden = !isHovered
        editButton.frame = NSRect(x: trailing - control, y: (b.height - control) / 2, width: control, height: control)
        trailing -= control + Metrics.space1
        addButton.frame = NSRect(x: trailing - control, y: (b.height - control) / 2, width: control, height: control)
        trailing -= control + Metrics.space2
        chevronFrame = CGRect(x: SidebarStyle.titleLeading, y: (b.height - chevronSide) / 2, width: chevronSide, height: chevronSide)
        chevron.frame = chevronFrame
        chevron.isHidden = false
        if badge.state.isUnread {
            badge.isHidden = false
            let w = badge.preferredWidth
            let h = SidebarStyle.badgeHeight
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
        let cw = ceil(count.attributedStringValue.size().width) + Metrics.space2
        let ch = ceil(count.intrinsicContentSize.height)
        count.isHidden = isHovered || badge.state.isUnread
        if !badge.state.isUnread {
            count.frame = NSRect(x: trailing - cw, y: (b.height - ch) / 2, width: cw, height: ch)
            trailing -= cw + Metrics.space2
        }
        // Caret, then the name inside its label (FlatSidebarTests, GroupLabelBandTests).
        let pad = Metrics.space3
        let chipX = chevronFrame.maxX + Metrics.space1
        let nx = chipX + pad
        let nh = ceil(name.intrinsicContentSize.height)
        let dotSide = SidebarStyle.dotSize
        let dotRoom: CGFloat = 0
        let pinSide = Metrics.smallIconSize
        let pinRoom = pinned ? pinSide + Metrics.space2 : 0
        let nameWidth = min(titleIntrinsicWidth, max(0, trailing - nx - pad - pinRoom))
        name.frame = NSRect(x: nx, y: (b.height - nh) / 2, width: nameWidth, height: nh)
        let chipHeight = min(b.height, max(Metrics.space6, b.height - 2 * Metrics.space3))
        pill.isHidden = renaming
        pill.frame = NSRect(x: chipX, y: (b.height - chipHeight) / 2, width: nameWidth + 2 * pad, height: chipHeight)
        pill.cornerRadius = max(0, SidebarStyle.rowCornerRadius - Metrics.space1)
        var x = pill.frame.maxX + Metrics.space2
        let dotFrame = CGRect(x: x, y: (b.height - dotSide) / 2, width: dotSide, height: dotSide)
        dot.frame = dotFrame
        dot.path = CGPath(ellipseIn: CGRect(origin: .zero, size: dotFrame.size).insetBy(dx: inset, dy: inset), transform: nil)
        x += dotRoom
        pin.isHidden = !pinned
        pin.frame = NSRect(x: x, y: (b.height - pinSide) / 2, width: pinSide, height: pinSide)
        needsDisplay = true
    }

    override func hoverChanged() {
        super.hoverChanged()
        needsLayout = true
    }
}

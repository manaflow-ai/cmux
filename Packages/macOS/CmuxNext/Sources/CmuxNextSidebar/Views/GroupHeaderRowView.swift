import AppKit
import CmuxNextDesign
import CmuxNextIcons
import QuartzCore

/// Group header: quiet text. The name aligns with workspace titles in the
/// secondary text color; a small dot follows it only when the user chose a
/// color. The disclosure chevron and child count appear on hover (the
/// chevron stays while collapsed). A collapsed group also surfaces its
/// children's activity and unread total.
final class GroupHeaderRowView: SidebarRowView {
    private let dot = CAShapeLayer()
    private let name = SidebarRowView.label(font: SidebarStyle.headerFont)
    private let count = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    private let chevron = NSImageView()
    private let activity = StatusIndicatorView()
    private let badge = UnreadBadgeView()
    private let pin = NSImageView()
    private let pill = CALayer()
    let addButton = SidebarIconButton(symbol: "plus", pointSize: { Metrics.smallIconSize - Metrics.space1 }, weight: .semibold, label: Strings.newWorkspace)
    let editButton = SidebarIconButton(symbol: "pencil", pointSize: { Metrics.smallIconSize - Metrics.space1 }, weight: .semibold, label: Strings.rename)
    private var pinned = false
    private var color: GroupColor = .grey
    private var collapsed = false
    private var chevronFrame: CGRect = .zero
    var isDropTarget = false { didSet { if isDropTarget != oldValue { needsDisplay = true } } }
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
    override var titleFont: NSFont { SidebarStyle.headerFont }
    private var renaming = false
    override func setTitleHidden(_ hidden: Bool) {
        renaming = hidden
        name.isHidden = hidden
    }

    override func updateLayer() {
        performWithTheme {
            name.textColor = Palette.textSecondary
            count.textColor = Palette.textTertiary
            pin.contentTintColor = Palette.textTertiary
            chevron.contentTintColor = Palette.textTertiary
            let tint = SidebarStyle.color(color)
            // Group headers use the title and color dot as their affordance.
            // Keep the layer allocated for reuse, but never render a capsule.
            pill.backgroundColor = nil
            // Fills only: a drop onto the group tints the row in its color.
            if isDropTarget {
                paintFill(color == .grey ? Palette.selectionFill : tint.withAlphaComponent(0.16))
            } else {
                paintFill(isHovered ? Palette.hoverFill : nil)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // A chosen color shows as a small dot: filled expanded, a ring collapsed.
            dot.isHidden = color == .grey
            dot.fillColor = collapsed ? nil : tint.cgColor
            dot.strokeColor = tint.cgColor
            dot.lineWidth = collapsed ? Metrics.dividerThickness * 1.5 : 0
            CATransaction.commit()
        }
    }

    /// The disclosure chevron: a click here toggles immediately.
    var disclosureFrame: NSRect { chevronFrame.insetBy(dx: -Metrics.space3, dy: -bounds.height) }

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
        pill.frame = .zero
        pill.isHidden = true
        let control = SidebarStyle.controlSize
        addButton.isHidden = !isHovered
        editButton.isHidden = !isHovered
        if !editButton.isHidden {
            editButton.frame = NSRect(x: trailing - control, y: (b.height - control) / 2,
                                      width: control, height: control)
            trailing -= control + Metrics.space1
        }
        if !addButton.isHidden {
            addButton.frame = NSRect(x: trailing - control, y: (b.height - control) / 2,
                                     width: control, height: control)
            trailing -= control + Metrics.space1
        }
        chevronFrame = CGRect(x: trailing - chevronSide, y: (b.height - chevronSide) / 2, width: chevronSide, height: chevronSide)
        chevron.frame = chevronFrame
        chevron.isHidden = !(isHovered || collapsed)
        trailing = chevronFrame.minX - Metrics.space2
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
        count.isHidden = !isHovered || badge.state.isUnread
        if !count.isHidden {
            count.frame = NSRect(x: trailing - cw, y: (b.height - ch) / 2, width: cw, height: ch)
            trailing -= cw + Metrics.space2
        }
        // The name starts where workspace titles start (FlatSidebarTests).
        let nx = SidebarStyle.titleLeading
        let nh = ceil(name.intrinsicContentSize.height)
        let dotSide = SidebarStyle.dotSize
        let dotRoom = color == .grey ? 0 : dotSide + Metrics.space3
        let pinSide = Metrics.smallIconSize
        let pinRoom = pinned ? pinSide + Metrics.space2 : 0
        let nameWidth = min(ceil(name.attributedStringValue.size().width) + Metrics.space2, max(0, trailing - nx - pinRoom - dotRoom))
        name.frame = NSRect(x: nx, y: (b.height - nh) / 2, width: nameWidth, height: nh)
        var x = name.frame.maxX + Metrics.space1
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

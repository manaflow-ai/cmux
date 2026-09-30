import AppKit
import CmuxNextDesign
import QuartzCore

/// Group header: a color dot and the name. The dot is filled while the group
/// is expanded and a ring while collapsed; the child count appears on hover.
/// A collapsed group also surfaces its children's activity and unread total.
final class GroupHeaderRowView: SidebarRowView {
    private let dot = CAShapeLayer()
    private let name = SidebarRowView.label(font: SidebarStyle.groupFont, color: Palette.textPrimary)
    private let count = SidebarRowView.label(font: SidebarStyle.subtitleFont, color: Palette.textSecondary)
    private let activity = ActivityIndicatorView()
    private let badge = UnreadBadgeView()
    private let pin = NSImageView()
    private var pinned = false
    private var color: GroupColor = .grey
    private var collapsed = false
    private var dotFrame: CGRect = .zero
    var isDropTarget = false { didSet { if isDropTarget != oldValue { needsDisplay = true } } }

    required init(key: SidebarRowKey) {
        super.init(key: key)
        layer?.addSublayer(dot)
        count.alignment = .right
        pin.contentTintColor = Palette.textSecondary
        [name, pin, count, activity, badge].forEach(addSubview)
    }

    override func prepareForReuse(key: SidebarRowKey) {
        super.prepareForReuse(key: key)
        isDropTarget = false
        collapsed = false
    }

    private struct Content: Hashable {
        var group: SidebarGroup
        var childCount: Int
        var collapsed: Bool
        var compact: Bool
        var fontSize: CGFloat
        var dotSize: CGFloat
    }

    func configure(_ group: SidebarGroup, row: SidebarRow, compact: Bool, animated: Bool) {
        let content = Content(
            group: group, childCount: row.childCount, collapsed: row.isCollapsed, compact: compact,
            fontSize: SidebarStyle.groupFont.pointSize, dotSize: SidebarStyle.groupDotSize
        )
        guard needsConfigure(content) else { return }
        self.compact = compact
        color = group.color
        name.stringValue = group.name
        name.font = SidebarStyle.groupFont
        count.font = SidebarStyle.subtitleFont
        count.stringValue = "\(row.childCount)"
        pinned = group.isPinned
        pin.image = pinned ? NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(SidebarStyle.chevronConfig) : nil
        collapsed = row.isCollapsed
        activity.configure(collapsed ? group.aggregateActivity : .idle)
        let unread = group.unreadTotal
        badge.configure(collapsed && unread > 0 ? .count(unread) : .none)
        toolTip = compact ? group.name : nil
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel("\(group.name), \(Strings.groupCount(row.childCount))")
        setAccessibilityExpanded(!collapsed)
        needsLayout = true
        needsDisplay = true
    }

    override var titleFrame: NSRect { name.frame }
    override var titleFont: NSFont { SidebarStyle.groupFont }
    private var renaming = false
    override func setTitleHidden(_ hidden: Bool) {
        renaming = hidden
        name.isHidden = hidden
    }

    override func updateLayer() {
        guard let layer else { return }
        let tint = SidebarStyle.color(color)
        // Fills only: a drop onto the group tints the row in its color.
        if isDropTarget {
            layer.backgroundColor = tint.withAlphaComponent(0.16).cgColor
        } else {
            layer.backgroundColor = isHovered ? resolvedCGColor(Palette.hoverFill) : nil
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.fillColor = collapsed ? nil : tint.cgColor
        dot.strokeColor = tint.cgColor
        dot.lineWidth = collapsed ? Metrics.dividerThickness * 1.5 : 0
        CATransaction.commit()
    }

    /// The color dot: a click here toggles immediately.
    var disclosureFrame: NSRect { dotFrame.insetBy(dx: -Metrics.space3, dy: -bounds.height) }

    override func layout() {
        super.layout()
        let b = layoutBounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let side = compact ? SidebarStyle.groupDotSize + Metrics.space1 : SidebarStyle.groupDotSize
        // The dot sits in the workspace icon column so names align with titles.
        let box = SidebarStyle.iconBox
        let boxX = compact ? (b.width - box) / 2 : Metrics.space3
        dotFrame = CGRect(x: boxX + (box - side) / 2, y: (b.height - side) / 2, width: side, height: side)
        dot.frame = dotFrame
        let inset = Metrics.dividerThickness
        dot.path = CGPath(ellipseIn: CGRect(origin: .zero, size: dotFrame.size).insetBy(dx: inset, dy: inset), transform: nil)
        needsDisplay = true

        if compact {
            [name, pin, count, badge, activity].forEach { $0.isHidden = true }
            return
        }
        name.isHidden = renaming

        var trailing = b.width - Metrics.space3
        if badge.state.isUnread {
            badge.isHidden = false
            let w = badge.preferredWidth
            let h = SidebarStyle.badgeHeight
            badge.frame = NSRect(x: trailing - w, y: (b.height - h) / 2, width: w, height: h)
            trailing = badge.frame.minX - Metrics.space2
        } else {
            badge.isHidden = true
        }
        if activity.activity != .idle {
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
        let nx = boxX + box + Metrics.space3
        let nh = ceil(name.intrinsicContentSize.height)
        let pinSide = Metrics.smallIconSize - Metrics.space2
        let pinRoom = pinned ? pinSide + Metrics.space2 : 0
        let nameWidth = min(ceil(name.attributedStringValue.size().width) + Metrics.space2, max(0, trailing - nx - pinRoom))
        name.frame = NSRect(x: nx, y: (b.height - nh) / 2, width: nameWidth, height: nh)
        pin.isHidden = !pinned
        pin.frame = NSRect(x: name.frame.maxX + Metrics.space1, y: (b.height - pinSide) / 2, width: pinSide, height: pinSide)
    }

    override func hoverChanged() {
        super.hoverChanged()
        needsLayout = true
    }
}

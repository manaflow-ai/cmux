import AppKit
import CmuxNextDesign
import QuartzCore

final class GroupHeaderRowView: SidebarRowView {
    private let chevron = NSImageView()
    private let folder = NSImageView()
    private let name = SidebarRowView.label(font: SidebarStyle.groupFont, color: Palette.textPrimary)
    private let count = SidebarRowView.label(font: SidebarStyle.subtitleFont, color: Palette.textSecondary)
    private let activity = ActivityIndicatorView()
    private let badge = UnreadBadgeView()
    private let pin = NSImageView()
    private var pinned = false
    private var color: GroupColor = .grey
    private var collapsed = false
    var isDropTarget = false { didSet { if isDropTarget != oldValue { needsDisplay = true } } }

    required init(key: SidebarRowKey) {
        super.init(key: key)
        chevron.contentTintColor = Palette.textSecondary
        chevron.wantsLayer = true
        folder.imageScaling = .scaleProportionallyDown
        count.alignment = .right
        pin.contentTintColor = Palette.textSecondary
        [chevron, folder, name, pin, count, activity, badge].forEach(addSubview)
    }

    override func prepareForReuse(key: SidebarRowKey) {
        super.prepareForReuse(key: key)
        isDropTarget = false
        collapsed = false
        chevron.frameCenterRotation = 0
    }

    private struct Content: Hashable {
        var group: SidebarGroup
        var childCount: Int
        var collapsed: Bool
        var compact: Bool
        var fontSize: CGFloat
        var iconSize: CGFloat
    }

    func configure(_ group: SidebarGroup, row: SidebarRow, compact: Bool, animated: Bool) {
        let content = Content(
            group: group, childCount: row.childCount, collapsed: row.isCollapsed, compact: compact,
            fontSize: SidebarStyle.groupFont.pointSize, iconSize: Metrics.smallIconSize
        )
        guard needsConfigure(content) else { return }
        self.compact = compact
        color = group.color
        name.stringValue = group.name
        name.font = SidebarStyle.groupFont
        count.font = SidebarStyle.subtitleFont
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(SidebarStyle.chevronConfig)
        count.stringValue = "\(row.childCount)"
        pinned = group.isPinned
        pin.image = pinned ? NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(SidebarStyle.chevronConfig) : nil
        let wasCollapsed = collapsed
        collapsed = row.isCollapsed
        let symbol = collapsed ? "folder.fill" : "folder"
        folder.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: compact ? Metrics.iconSize : Metrics.smallIconSize, weight: .semibold))
        folder.contentTintColor = SidebarStyle.color(group.color)
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
        if wasCollapsed != collapsed { rotateChevron(animated: animated) } else { rotateChevron(animated: false) }
    }

    private func rotateChevron(animated: Bool) {
        let target: CGFloat = collapsed ? 0 : 90
        if animated && !Motion.reduceMotion {
            Motion.animate(Motion.layout) { chevron.animator().frameCenterRotation = target }
        } else {
            chevron.frameCenterRotation = target
        }
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
        if isDropTarget {
            layer.backgroundColor = SidebarStyle.color(color).withAlphaComponent(0.18).cgColor
            layer.borderColor = SidebarStyle.color(color).withAlphaComponent(0.55).cgColor
            layer.borderWidth = 1
        } else {
            layer.backgroundColor = isHovered ? resolvedCGColor(Palette.hoverFill) : nil
            layer.borderWidth = 0
        }
    }

    /// The chevron and folder icon: a click here toggles immediately.
    var disclosureFrame: NSRect { chevron.frame.union(folder.frame).insetBy(dx: -Metrics.space1, dy: -bounds.height) }

    override func layout() {
        super.layout()
        let b = layoutBounds
        if compact {
            [chevron, name, pin, count, badge, activity].forEach { $0.isHidden = true }
            let side = SidebarStyle.iconBox
            folder.frame = NSRect(x: (b.width - side) / 2, y: (b.height - side) / 2, width: side, height: side)
            return
        }
        chevron.isHidden = false
        name.isHidden = renaming
        let chevronSide = Metrics.smallIconSize
        let rotation = chevron.frameCenterRotation
        chevron.frameCenterRotation = 0
        chevron.frame = NSRect(x: Metrics.space2, y: (b.height - chevronSide) / 2, width: chevronSide, height: chevronSide)
        chevron.frameCenterRotation = rotation
        let folderSide = Metrics.iconSize
        folder.frame = NSRect(x: chevron.frame.maxX + Metrics.space1, y: (b.height - folderSide) / 2, width: folderSide, height: folderSide)

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
        let cw = ceil(count.attributedStringValue.size().width) + 4
        let ch = ceil(count.intrinsicContentSize.height)
        count.isHidden = !(isHovered || collapsed) || badge.state.isUnread
        if !count.isHidden {
            count.frame = NSRect(x: trailing - cw, y: (b.height - ch) / 2, width: cw, height: ch)
            trailing -= cw + Metrics.space2
        }
        let nx = folder.frame.maxX + Metrics.space3
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

// MARK: - Section header

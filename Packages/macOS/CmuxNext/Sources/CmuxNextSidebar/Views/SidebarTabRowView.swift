import AppKit
import CmuxNextDesign
import CmuxNextIcons
import QuartzCore

/// A compact tab row shown below a workspace when tab listing is enabled.
final class SidebarTabRowView: SidebarRowView {
    private let icon = NSImageView()
    private let title = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    private let groupRail = CALayer()
    private let rails = [CALayer(), CALayer()]
    private var unread = false
    private var kind: SidebarTabKind = .terminal
    private var groupColor: GroupColor?

    private struct Content: Hashable {
        var tab: SidebarTab
        var group: GroupID?
        var groupColor: GroupColor?
    }

    required init(key: SidebarRowKey) {
        super.init(key: key)
        layer?.addSublayer(groupRail)
        rails.forEach { layer?.addSublayer($0) }
        [icon, title].forEach(addSubview)
    }

    override func prepareForReuse(key: SidebarRowKey) {
        super.prepareForReuse(key: key)
        unread = false
        kind = .terminal
        groupColor = nil
    }

    func configure(_ tab: SidebarTab, row: SidebarRow) {
        let content = Content(tab: tab, group: row.group, groupColor: row.groupColor)
        guard needsConfigure(content) else { return }
        title.stringValue = tab.title
        title.font = tab.isUnread ? SidebarStyle.titleUnreadFont : SidebarStyle.subtitleFont
        kind = tab.kind
        unread = tab.isUnread
        groupColor = row.groupColor
        icon.image = NSImage.icon(tab.kind.icon, size: SidebarStyle.tabIconSize)
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityLabel(tab.title)
        needsLayout = true
        needsDisplay = true
    }

    override func updateLayer() {
        performWithTheme {
            icon.contentTintColor = unread ? Palette.textPrimary : Palette.textTertiary
            title.textColor = unread ? Palette.textPrimary : Palette.textSecondary
            paintFill(isHovered ? Palette.hoverFill : nil)
            let groupTint = groupColor.flatMap { $0.swatch.blended(withFraction: 0.25, of: Palette.accent) }
            let groupRailWidth = max(Metrics.dividerThickness * 2, 2)
            groupRail.backgroundColor = groupTint?.cgColor
            groupRail.cornerRadius = groupRailWidth / 2
            groupRail.isHidden = groupColor == nil
            let color = SidebarStyle.color(kind == .browser ? .blue : .grey)
            for rail in rails { rail.backgroundColor = color.withAlphaComponent(0.75).cgColor }
        }
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        let groupRailWidth = max(Metrics.dividerThickness * 2, 2)
        groupRail.frame = NSRect(
            x: SidebarStyle.horizontalInset - Metrics.space2,
            y: Metrics.space1,
            width: groupRailWidth,
            height: max(0, b.height - Metrics.space2)
        )
        groupRail.cornerRadius = groupRailWidth / 2
        let railWidth = max(Metrics.dividerThickness, 1)
        let gap = Metrics.space1
        let railX = SidebarStyle.horizontalInset + Metrics.space1
        for (index, rail) in rails.enumerated() {
            rail.frame = NSRect(x: railX + CGFloat(index) * (railWidth + gap), y: Metrics.space1,
                                 width: railWidth, height: max(0, b.height - Metrics.space2))
            rail.cornerRadius = railWidth / 2
        }
        let iconSide = SidebarStyle.tabIconSize
        let iconX = railX + railWidth * 2 + gap * 2
        icon.frame = NSRect(x: iconX, y: (b.height - iconSide) / 2, width: iconSide, height: iconSide)
        let textX = icon.frame.maxX + Metrics.space2
        title.frame = NSRect(x: textX, y: (b.height - title.intrinsicContentSize.height) / 2,
                             width: max(0, b.width - textX - Metrics.space3), height: title.intrinsicContentSize.height)
    }
}

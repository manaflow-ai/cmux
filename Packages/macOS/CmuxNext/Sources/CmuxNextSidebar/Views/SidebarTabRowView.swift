import AppKit
import CmuxAgentBrands
import CmuxNextDesign
import CmuxNextIcons

/// A compact tab row shown below a workspace when tab listing is enabled. It
/// reads as the workspace's child by indent and icon alone, no bars: a
/// grouped workspace's line is the only bar in a hierarchy (cx-ai79).
final class SidebarTabRowView: SidebarRowView {
    private let icon = NSImageView()
    private let title = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    private var unread = false
    /// Activates this tab from an accessibility AXPress.
    var onSelect: (() -> Void)?

    private struct Content: Hashable {
        var tab: SidebarTab
        var group: GroupID?
        var groupColor: GroupColor?
    }

    required init(key: SidebarRowKey) {
        super.init(key: key)
        [icon, title].forEach(addSubview)
    }

    override func prepareForReuse(key: SidebarRowKey) {
        super.prepareForReuse(key: key)
        unread = false
        onSelect = nil
    }

    func configure(_ tab: SidebarTab, row: SidebarRow) {
        let content = Content(tab: tab, group: row.group, groupColor: row.groupColor)
        guard needsConfigure(content) else { return }
        title.stringValue = tab.title
        title.font = tab.isUnread ? SidebarStyle.titleUnreadFont : SidebarStyle.subtitleFont
        unread = tab.isUnread
        icon.image = tab.brand.flatMap { AgentBrandCatalog.templateImage(brand: $0, size: SidebarStyle.tabIconSize) }
            ?? NSImage.icon(tab.kind.icon, size: SidebarStyle.tabIconSize)
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        let workspaceIdentifier = row.workspace?.rawValue ?? "unknown"
        setAccessibilityIdentifier("cmux.sidebar.tab.\(workspaceIdentifier).\(tab.id.rawValue)")
        setAccessibilityLabel(tab.title)
        needsLayout = true
        needsDisplay = true
    }

    /// Routes AXPress through the sidebar's shared tab selection action.
    override func accessibilityPerformPress() -> Bool {
        guard let onSelect else { return false }
        onSelect()
        return true
    }

    override func updateLayer() {
        performWithTheme {
            icon.contentTintColor = unread ? Palette.textPrimary : Palette.textTertiary
            title.textColor = unread ? Palette.textPrimary : Palette.textSecondary
            paintFill(isHovered ? Palette.hoverFill : nil)
        }
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        // A grouped tab row starts right of its group's line (SidebarListView.frame(for:)).
        let iconSide = SidebarStyle.tabIconSize
        let iconX = SidebarStyle.titleLeading + Metrics.space3
        icon.frame = NSRect(x: iconX, y: (b.height - iconSide) / 2, width: iconSide, height: iconSide)
        let textX = icon.frame.maxX + Metrics.space2
        title.frame = NSRect(x: textX, y: (b.height - title.intrinsicContentSize.height) / 2,
                             width: max(0, b.width - textX - Metrics.space3), height: title.intrinsicContentSize.height)
    }
}

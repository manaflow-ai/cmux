import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// A compact tab row shown below a workspace when tab listing is enabled. It
/// reads as the workspace's child by indent alone, no bars: a grouped
/// workspace's line is the only bar in a hierarchy (cx-ai79). It draws no
/// kind or agent glyph; only a browser tab's page favicon (Lawrence
/// 2026-10-14, cx-im75u).
final class SidebarTabRowView: SidebarRowView {
    private let icon = NSImageView()
    private let title = SidebarRowView.label(font: SidebarStyle.subtitleFont)
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

    override var debugIcon: String? { icon.isHidden ? nil : "favicon" }

    override func prepareForReuse(key: SidebarRowKey) {
        super.prepareForReuse(key: key)
        onSelect = nil
    }

    func configure(_ tab: SidebarTab, row: SidebarRow) {
        let content = Content(tab: tab, group: row.group, groupColor: row.groupColor)
        guard needsConfigure(content) else { return }
        title.stringValue = tab.title
        // Regular weight and the primary text color, read or unread (Lawrence 2026-10-14).
        title.font = SidebarStyle.subtitleFont
        // Only a page's favicon draws, as is; no kind or agent glyph.
        let side = SidebarStyle.tabIconSize
        icon.image = tab.favicon.map { NSImage(cgImage: $0.image, size: NSSize(width: side, height: side)) }
        icon.isHidden = icon.image == nil
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
            title.textColor = Palette.textPrimary
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
        // Without a favicon the title takes the icon's place.
        let textX = icon.isHidden ? iconX - SidebarStyle.labelCellPadding : icon.frame.maxX + Metrics.space2
        title.frame = NSRect(x: textX, y: (b.height - title.intrinsicContentSize.height) / 2,
                             width: max(0, b.width - textX - Metrics.space3), height: title.intrinsicContentSize.height)
    }
}

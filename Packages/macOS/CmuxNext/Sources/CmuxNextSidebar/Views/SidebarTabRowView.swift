import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// A compact tab row shown below a workspace when tab listing is enabled. It
/// reads as the workspace's child by indent alone, no bars: a grouped
/// workspace's line is the only bar in a hierarchy (cx-ai79). It draws no
/// kind or agent glyph; only a browser tab's page favicon (Lawrence
/// 2026-10-14, cx-im75u). An unread tab shows a small muted unread dot
/// at its trailing edge; its title keeps the primary color and regular weight.
final class SidebarTabRowView: SidebarRowView {
    private let icon = DecorativeImageView() // the row's label names the tab
    private let title = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    /// The unread dot: a workspace row's dot (`UnreadBadgeView`, same shape and size) in the quiet, muted look.
    private let unreadDot = UnreadBadgeView()
    /// Activates this tab from an accessibility AXPress.
    var onSelect: (() -> Void)?

    private struct Content: Hashable {
        var tab: SidebarTab
        var group: GroupID?
        var groupColor: GroupColor?
    }

    required init(key: SidebarRowKey) {
        super.init(key: key)
        [icon, title, unreadDot].forEach(addSubview)
        unreadDot.fixedLook = .quiet
    }

    override var debugIcon: String? { icon.isHidden ? nil : "favicon" }

    override func prepareForReuse(key: SidebarRowKey) {
        super.prepareForReuse(key: key)
        onSelect = nil
    }

    func configure(_ tab: SidebarTab, row: SidebarRow) {
        let content = Content(tab: tab, group: row.group, groupColor: row.groupColor)
        guard needsConfigure(content) else { return }
        title.setString(tab.title)
        // Regular weight and the primary text color, read or unread (Lawrence 2026-10-14).
        title.setFont(SidebarStyle.subtitleFont)
        // Only a page's favicon draws, as is; no kind or agent glyph.
        let side = SidebarStyle.tabIconSize
        icon.image = tab.favicon.map { NSImage(cgImage: $0.image, size: NSSize(width: side, height: side)) }
        icon.isHidden = icon.image == nil
        unreadDot.configure(tab.isUnread ? .dot : .none)
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        let workspaceIdentifier = row.workspace?.rawValue ?? "unknown"
        setAccessibilityIdentifier("cmux.sidebar.tab.\(workspaceIdentifier).\(tab.id.rawValue)")
        // The dot is drawn only: the label says it ("zsh, Unread").
        setAccessibilityLabel(tab.isUnread ? tab.title + ", " + Strings.unreadDot : tab.title)
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
            title.setColor(Palette.textPrimary)
            paintFill(isHovered ? Palette.hoverFill : nil)
        }
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        // A grouped tab row keeps an ungrouped one's left edge (SidebarListView.frame(for:)).
        let iconSide = SidebarStyle.tabIconSize
        let iconX = SidebarStyle.titleLeading + Metrics.space3
        icon.frame = NSRect(x: iconX, y: (b.height - iconSide) / 2, width: iconSide, height: iconSide)
        // Without a favicon the title takes the icon's place (Lawrence 2026-10-23: "as left as possible").
        let textX = icon.isHidden ? iconX - SidebarStyle.labelCellPadding : icon.frame.maxX + Metrics.space2
        // The dot sits where a workspace row's dot does: its slot at the row's trailing inset.
        var trailing = b.width - SidebarStyle.horizontalInset
        if unreadDot.state.isUnread {
            let side = SidebarStyle.dotSize
            unreadDot.frame = NSRect(x: trailing - side - Metrics.space2, y: (b.height - side) / 2, width: side, height: side)
            trailing = unreadDot.frame.minX - Metrics.space2
        }
        title.frame = NSRect(x: textX, y: (b.height - title.intrinsicContentSize.height) / 2,
                             width: max(0, trailing - textX), height: title.intrinsicContentSize.height)
    }
}

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
    /// A nested sub-session's state (SidebarSubsessionRow), in the icon's place.
    private let indicator = StatusIndicatorView()
    /// A nested row's trailing text: a header's count, a sub-session's queued prompts.
    private let trailingText = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    /// The nested row this view draws; nil for a tab.
    private var nested: SidebarSubsessionRow?
    /// Activates this tab from an accessibility AXPress.
    var onSelect: (() -> Void)?

    private struct Content: Hashable {
        var tab: SidebarTab
        var group: GroupID?
        var groupColor: GroupColor?
    }

    required init(key: SidebarRowKey) {
        super.init(key: key)
        [icon, indicator, title, trailingText, unreadDot].forEach(addSubview)
        unreadDot.fixedLook = .quiet
        indicator.isHidden = true
        trailingText.isHidden = true
    }

    override var debugIcon: String? { icon.isHidden ? nil : "favicon" }

    override func prepareForReuse(key: SidebarRowKey) {
        super.prepareForReuse(key: key)
        onSelect = nil
    }

    func configure(_ tab: SidebarTab, row: SidebarRow) {
        let content = Content(tab: tab, group: row.group, groupColor: row.groupColor)
        guard needsConfigure(content) else { return }
        showNested(nil)
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
        setAccessibilityLabel(tab.title)
        needsLayout = true
        needsDisplay = true
    }

    /// A row nested under an agent chat tab: the header of its sub-sessions (a disclosure and their
    /// count) or one sub-session (its state in the icon's place, indented by its depth, an unread
    /// dot and its queued prompts).
    func configure(_ row: SidebarSubsessionRow, row layoutRow: SidebarRow) {
        let content = NestedContent(row: row, group: layoutRow.group, groupColor: layoutRow.groupColor)
        guard needsConfigure(content) else { return }
        showNested(row)
        title.setFont(SidebarStyle.subtitleFont)
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        let workspaceIdentifier = layoutRow.workspace?.rawValue ?? "unknown"
        setAccessibilityIdentifier("cmux.sidebar.subsession.\(workspaceIdentifier).\(row.id.rawValue)")
        switch row.kind {
        case let .header(count, expanded):
            title.setString(Strings.subsessions)
            icon.image = SidebarStyle.chevron(collapsed: !expanded)
            icon.isHidden = false
            indicator.configure(.idle)
            indicator.isHidden = true
            trailingText.setString(String(count))
            trailingText.isHidden = false
            unreadDot.configure(.none)
            setAccessibilityLabel(Strings.subsessions)
            setAccessibilityValue(String(count))
            setAccessibilityExpanded(expanded)
        case let .session(subsession):
            title.setString(subsession.title)
            icon.image = nil
            icon.isHidden = true
            indicator.configure(subsession.state.indicator)
            indicator.isHidden = subsession.state == .idle
            trailingText.setString(subsession.queued > 0 ? Strings.subsessionQueued(subsession.queued) : "")
            trailingText.isHidden = subsession.queued == 0
            unreadDot.configure(subsession.isUnread ? .dot : .none)
            let parts = [subsession.title, Strings.activity(subsession.state.indicator),
                         subsession.isUnread ? Strings.unreadDot : nil, trailingText.isHidden ? nil : trailingText.stringValue]
            setAccessibilityLabel(parts.compactMap { $0 }.joined(separator: ", "))
            setAccessibilityValue(nil)
        }
        needsLayout = true
        needsDisplay = true
    }

    private struct NestedContent: Hashable {
        var row: SidebarSubsessionRow
        var group: GroupID?
        var groupColor: GroupColor?
    }

    /// Switches the view between a tab (nil) and a nested row; a reused view starts clean.
    private func showNested(_ row: SidebarSubsessionRow?) {
        nested = row
        guard row == nil else { return }
        indicator.configure(.idle)
        indicator.isHidden = true
        trailingText.isHidden = true
        setAccessibilityValue(nil)
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
            trailingText.setColor(Palette.textSecondary)
            paintFill(isHovered ? Palette.hoverFill : nil)
        }
    }

    override func layout() {
        super.layout()
        if let nested { return layoutNested(nested) }
        let b = layoutBounds
        // A grouped tab row starts right of its group's line (SidebarListView.frame(for:)).
        let iconSide = SidebarStyle.tabIconSize
        let iconX = SidebarStyle.titleLeading + Metrics.space3
        icon.frame = NSRect(x: iconX, y: (b.height - iconSide) / 2, width: iconSide, height: iconSide)
        // Without a favicon the title takes the icon's place.
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

    /// A nested row: indented one step under the tab rows (a sub-session one more per depth), the
    /// header's chevron or the sub-session's state in the icon slot, the trailing text and the
    /// unread dot at the trailing edge.
    private func layoutNested(_ row: SidebarSubsessionRow) {
        let b = layoutBounds
        var depth = 0
        if case let .session(subsession) = row.kind { depth = subsession.depth }
        let side = SidebarStyle.tabIconSize
        let slotX = SidebarStyle.titleLeading + Metrics.space3 + CGFloat(depth) * Metrics.space3
        icon.frame = NSRect(x: slotX, y: (b.height - side) / 2, width: side, height: side)
        let mark = SidebarStyle.indicatorSize
        indicator.frame = NSRect(x: slotX + (side - mark) / 2, y: (b.height - mark) / 2, width: mark, height: mark)
        let textX = slotX + side + Metrics.space2 - SidebarStyle.labelCellPadding
        var trailing = b.width - SidebarStyle.horizontalInset
        if unreadDot.state.isUnread {
            let dot = SidebarStyle.dotSize
            unreadDot.frame = NSRect(x: trailing - dot - Metrics.space2, y: (b.height - dot) / 2, width: dot, height: dot)
            trailing = unreadDot.frame.minX - Metrics.space2
        }
        if !trailingText.isHidden {
            let size = trailingText.intrinsicContentSize
            let width = min(ceil(size.width), max(0, (trailing - textX) / 2))
            trailingText.frame = NSRect(x: trailing - width, y: (b.height - size.height) / 2, width: width, height: size.height)
            trailing = trailingText.frame.minX - Metrics.space2
        }
        title.frame = NSRect(x: textX, y: (b.height - title.intrinsicContentSize.height) / 2,
                             width: max(0, trailing - textX), height: title.intrinsicContentSize.height)
    }
}

import AppKit

extension WorkspaceRowView {
    /// Routes AXPress through the sidebar's shared workspace selection action.
    override func accessibilityPerformPress() -> Bool {
        guard !isShowingPlaceholder, let onSelect else { return false }
        onSelect()
        return true
    }

    /// Show Tabs or Hide Tabs on every row with tabs: the chevron shows only
    /// on hover or selection (cx-fo2t), and a hidden button leaves the
    /// accessibility tree.
    /// The row's menu as well: the more button shows only on hover (Lawrence 2026-10-11).
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        var actions = super.accessibilityCustomActions() ?? []
        guard !isShowingPlaceholder else { return actions.isEmpty ? nil : actions }
        if let disclosure, disclosure != .empty, let onToggleTabs {
            let name = disclosure == .expanded ? Strings.hideTabs : Strings.showTabs
            actions.append(NSAccessibilityCustomAction(name: name) { onToggleTabs(); return true })
        }
        if let onMore {
            actions.append(NSAccessibilityCustomAction(name: Strings.workspaceMenu) { onMore(); return true })
        }
        return actions.isEmpty ? nil : actions
    }

    func accessibilityText(_ ws: SidebarWorkspace, content: WorkspaceRowContent) -> String {
        var parts = [ws.title]
        if let s = content.detail { parts.append(s) }
        // The chip's word takes the one-line status's place, as drawn.
        if let s = content.chip.map({ SidebarPriorityRowView.chipText($0, now: Date()) }) ?? content.trailingStatus { parts.append(s) }
        if let s = content.status?.searchText, !s.isEmpty { parts.append(s) }
        if let s = content.badge { parts.append(s) }
        if let badge = content.pullRequests { parts.append(Strings.pullRequests(badge)) }
        if let value = content.progress?.value { parts.append(Strings.progressPercent(Int((value * 100).rounded()))) }
        if let count { parts.append(Strings.tabCount(count)) }
        switch ws.unread {
        case let .count(n) where n > 0: parts.append(Strings.unreadCount(n))
        case .dot: parts.append(Strings.unreadDot)
        default: break
        }
        if let text = Strings.activity(content.activity) { parts.append(text) }
        if ws.muted { parts.append(Strings.notificationsMuted) }
        if !presenceDots.isHidden { parts += presenceDots.presence.map(Strings.presenceLine) }
        return parts.joined(separator: ", ")
    }
}

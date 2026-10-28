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
        if let treeFold, let onToggleTree {
            let name = treeFold == .collapsed ? Strings.expandSessions : Strings.collapseSessions
            actions.append(NSAccessibilityCustomAction(name: name) { onToggleTree(); return true })
        }
        if let onMore {
            actions.append(NSAccessibilityCustomAction(name: Strings.workspaceMenu) { onMore(); return true })
        }
        return actions.isEmpty ? nil : actions
    }

    func accessibilityText(_ ws: SidebarWorkspace, content: WorkspaceRowContent, title: String? = nil) -> String {
        Self.accessibilityText(ws, content: content, tabCount: count, presence: presenceDots.isHidden ? [] : presenceDots.presence,
                               title: title)
    }

    /// The row's label: what it draws, in reading order. `tabCount` and `presence` are what the
    /// row's tab count and presence dots show (nil and empty when hidden). `title` is the name the
    /// row reads (`SidebarWorkspace.spokenRowTitle`), nil for the workspace's.
    static func accessibilityText(_ ws: SidebarWorkspace, content: WorkspaceRowContent, tabCount count: Int?,
                                  presence: [SidebarPresence], title: String? = nil) -> String {
        var parts = [title ?? ws.title]
        let detail = content.now.map(Strings.rowNow) ?? content.detail
        if let detail { parts.append(detail) }
        // The chip's word (never drawn: no status words on a row), else the one-line status the row draws.
        if let s = content.chip.map({ SidebarPriorityRowView.chipText($0, now: Date()) }) ?? content.trailingStatus { parts.append(s) }
        if let s = content.status?.searchText, !s.isEmpty { parts.append(s) }
        if let s = content.badge { parts.append(s) }
        if let badge = content.pullRequests { parts.append(Strings.pullRequests(badge)) }
        if let rollUp = content.rollUp { parts.append(Strings.rollUp(rollUp)) }
        if let value = content.progress?.value { parts.append(Strings.progressPercent(Int((value * 100).rounded()))) }
        if let count { parts.append(Strings.tabCount(count)) }
        switch ws.unread {
        case let .count(n) where n > 0: parts.append(Strings.unreadCount(n))
        case .dot: parts.append(Strings.unreadDot)
        default: break
        }
        if let text = Strings.activity(content.activity) { parts.append(text) }
        if ws.muted { parts.append(Strings.notificationsMuted) }
        // A one-list row on another computer leads its second line with the computer's name
        // (`SidebarLayout.machineLabel`): VoiceOver says it once. The whole name is compared, so a
        // name with " · " in it still counts.
        if let machine = content.machine,
           !(detail == machine.name || detail?.hasPrefix(machine.name + WorkspaceRowContent.separator) == true) {
            parts.append(machine.name)
        }
        parts += presence.map(Strings.presenceLine)
        return parts.joined(separator: ", ")
    }
}

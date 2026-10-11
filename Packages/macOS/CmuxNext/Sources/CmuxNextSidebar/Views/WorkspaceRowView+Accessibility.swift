import AppKit

extension WorkspaceRowView {
    /// Routes AXPress through the sidebar's shared workspace selection action.
    override func accessibilityPerformPress() -> Bool {
        guard !isShowingPlaceholder, let onSelect else { return false }
        onSelect()
        return true
    }

    func accessibilityText(_ ws: SidebarWorkspace, content: WorkspaceRowContent) -> String {
        var parts = [ws.title]
        if let s = content.detail { parts.append(s) }
        if let s = content.badge { parts.append(s) }
        if let value = content.progress?.value { parts.append(Strings.progressPercent(Int((value * 100).rounded()))) }
        if let count { parts.append(Strings.tabCount(count)) }
        switch ws.unread {
        case let .count(n) where n > 0: parts.append(Strings.unreadCount(n))
        case .dot: parts.append(Strings.unreadDot)
        default: break
        }
        if let text = Strings.activity(content.activity) { parts.append(text) }
        if ws.muted { parts.append(Strings.muted) }
        if !presenceDots.isHidden { parts += presenceDots.presence.map(Strings.presenceLine) }
        return parts.joined(separator: ", ")
    }
}

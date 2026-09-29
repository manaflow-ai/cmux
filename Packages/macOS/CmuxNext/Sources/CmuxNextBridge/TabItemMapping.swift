public import CmuxNextDaemon
public import CmuxNextTabs

/// Maps daemon tab records into tab strip items.
public enum TabItemMapping {
    /// `fallbackTitle` names a tab whose program set no title yet
    /// (localized by the App).
    public static func item(_ tab: TabModel, fallbackTitle: String) -> StripTabItem {
        let title = tab.displayTitle.isEmpty ? fallbackTitle : tab.displayTitle
        let isBrowser = tab.kind == .browser
        return StripTabItem(
            id: StripTabID(tab.id),
            title: title,
            subtitle: isBrowser ? tab.url : tab.cwd.map(SidebarMapping.abbreviate),
            icon: .symbol(isBrowser ? "globe" : (tab.dead ? "xmark.octagon" : "terminal")),
            isPinned: tab.pinned,
            isUnread: tab.hasUnread,
            isBusy: tab.agent?.state == .working,
            status: status(tab)
        )
    }

    static func status(_ tab: TabModel) -> TabStatus {
        switch tab.agent?.state {
        case .blocked: .needsInput
        case .done: .success
        default: tab.dead ? .failure : .none
        }
    }
}

public import CmuxNextDaemon
public import CmuxNextTabs

/// Maps daemon tab records into tab strip items.
public struct TabItemMapping {
    public static let shared = Self()
    /// `fallbackTitle` names a tab whose program set no title yet
    /// (localized by the App).
    public func item(_ tab: TabModel, fallbackTitle: String) -> StripTabItem {
        let title = tab.displayTitle.isEmpty ? fallbackTitle : tab.displayTitle
        let isBrowser = tab.kind == .browser
        let busy = StatusMapping.shared.loading(tab)
        var item = StripTabItem(
            id: StripTabID(tab.id),
            title: title,
            subtitle: isBrowser ? tab.url : tab.cwd.map(SidebarMapping.shared.abbreviate),
            icon: .symbol(isBrowser ? "globe" : (tab.dead ? "xmark.octagon" : "terminal")),
            isPinned: tab.pinned,
            isUnread: tab.hasUnread,
            isBusy: busy.state.isLoading,
            status: status(tab),
            // The strip's location field: web pages only (`TabLocation`).
            location: isBrowser ? TabLocation(address: tab.url) : nil
        )
        if busy.state.isLoading { item.indicator = busy.state }
        item.busyStyle = busy.style
        return item
    }

    func status(_ tab: TabModel) -> TabStatus {
        switch tab.agent?.state {
        case .blocked: .needsInput
        case .done: .success
        default: tab.dead ? .failure : .none
        }
    }
}

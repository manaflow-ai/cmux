public import CmuxNextDaemon
public import CmuxNextTabs

/// Maps daemon tab records into tab strip items.
public struct TabItemMapping {
    public static let shared = Self()
    /// `fallbackTitle` names a tab whose program set no title yet
    /// (localized by the App), and a browser tab on the New Tab or blank
    /// page, whose recorded title is that page's address.
    public func item(_ tab: TabModel, fallbackTitle: String) -> StripTabItem {
        let isBrowser = tab.kind == .browser
        let untitled = tab.displayTitle.isEmpty || (isBrowser && Self.isBlankPageAddress(tab.displayTitle))
        let title = untitled ? fallbackTitle : tab.displayTitle
        let busy = StatusMapping.shared.loading(tab)
        var item = StripTabItem(
            id: StripTabID(tab.id),
            title: title,
            subtitle: isBrowser ? tab.url : tab.cwd.map(SidebarMapping.shared.abbreviate),
            icon: .symbol(isBrowser ? "globe" : (tab.dead ? "xmark.octagon" : "terminal")),
            isPinned: tab.pinned,
            isUnread: tab.hasUnread,
            isBusy: busy.state.isLoading || isReportingProgress(tab),
            status: status(tab),
            // The strip's location field: web pages only (`TabLocation`).
            location: isBrowser ? TabLocation(address: tab.url) : nil
        )
        if busy.state.isLoading { item.indicator = busy.state }
        item.busyStyle = busy.style
        return item
    }

    /// The New Tab page's and the blank page's addresses
    /// (`BrowserNewTabPage` in CmuxNextBrowser), which a page that never
    /// names itself keeps as its title.
    static func isBlankPageAddress(_ text: String) -> Bool {
        ["chrome://newtab/", "chrome://newtab", "about:blank"].contains(text.lowercased())
    }

    func status(_ tab: TabModel) -> TabStatus {
        switch tab.agent?.state {
        case .blocked: .needsInput
        case .done: .success
        default: tab.dead || tab.progress?.state == .error ? .failure : .none
        }
    }

    /// The daemon parsed running OSC 9;4 progress for the tab's terminal
    /// (every terminal, shown or not).
    func isReportingProgress(_ tab: TabModel) -> Bool {
        switch tab.progress?.state {
        case .normal?, .indeterminate?: true
        default: false
        }
    }
}

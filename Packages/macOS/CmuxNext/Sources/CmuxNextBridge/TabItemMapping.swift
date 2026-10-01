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
        return StripTabItem(
            id: StripTabID(tab.id),
            title: title,
            subtitle: isBrowser ? tab.url : tab.cwd.map(SidebarMapping.shared.abbreviate),
            icon: .symbol(isBrowser ? "globe" : (tab.dead ? "xmark.octagon" : "terminal")),
            isPinned: tab.pinned,
            isUnread: tab.hasUnread,
            isBusy: tab.agent?.state == .working || isReportingProgress(tab),
            status: status(tab)
        )
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
    static func isReportingProgress(_ tab: TabModel) -> Bool {
        switch tab.progress?.state {
        case .normal?, .indeterminate?: true
        default: false
        }
    }
}

import CmuxAgentBrands
import Foundation
public import CmuxNextDaemon
public import CmuxNextTabs

/// Maps daemon tab records into tab strip items.
public struct TabItemMapping {
    public static let shared = Self()
    /// `fallbackTitle` names a tab whose program set no title yet
    /// (localized by the App), and a browser tab on the New Tab or blank
    /// page, whose recorded title is that page's address.
    /// A conversation tab (conversation-tabs-v1) rides a frontend browser
    /// record titled with the blank page's address: it shows `fallbackTitle`
    /// (the conversation's) and this symbol.
    public static let conversationSymbol = "bubble.left.and.bubble.right"

    public func item(_ tab: TabModel, fallbackTitle: String) -> StripTabItem {
        let isBrowser = tab.kind == .browser
        let isConversation = tab.kind == .conversation
        let untitled = tab.displayTitle.isEmpty || ((isBrowser || isConversation) && Self.isBlankPageAddress(tab.displayTitle))
        let title = untitled ? fallbackTitle : isBrowser ? Self.browserTitle(tab) : tab.displayTitle
        let busy = StatusMapping.shared.loading(tab)
        var item = StripTabItem(
            id: StripTabID(tab.id),
            title: title,
            subtitle: isConversation ? nil : isBrowser ? tab.url : tab.cwd.map(SidebarMapping.shared.abbreviate),
            icon: icon(tab, isBrowser: isBrowser, isConversation: isConversation),
            isPinned: tab.pinned,
            isUnread: tab.hasUnread,
            isBusy: busy.state.isLoading || isReportingProgress(tab),
            status: status(tab)
        )
        if busy.state.isLoading { item.indicator = busy.state }
        item.busyStyle = busy.style
        return item
    }

    /// A live agent terminal wears its agent's brand mark (design/agent-icons); other
    /// terminals, and agents without a mark, keep the terminal symbol.
    func icon(_ tab: TabModel, isBrowser: Bool, isConversation: Bool) -> TabIcon {
        if isConversation { return .symbol(Self.conversationSymbol) }
        if isBrowser { return .symbol("globe") }
        if tab.dead { return .symbol("xmark.octagon") }
        if let brand = AgentBrandCatalog.brand(for: tab.agent?.agent) { return .agentMark(brand.rawValue) }
        return .symbol("terminal")
    }

    /// A browser tab whose page was never shown keeps the record the daemon
    /// wrote at creation, titled with the full address: it shows the host
    /// until the page reports its own title. A user name, a page title and
    /// an address without a host (file:) stay as they are.
    static func browserTitle(_ tab: TabModel) -> String {
        let title = tab.displayTitle
        guard tab.name?.isEmpty ?? true, title == tab.url,
              let host = URL(string: title)?.host(), !host.isEmpty else { return title }
        return host
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

import CmuxAgentBrands
import CmuxNextIcons
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
    /// (the conversation's) and the agent chat icon. `isNewTabPage` marks a
    /// tab still on the New Tab page, which draws the new-tab icon instead.

    public func item(_ tab: TabModel, fallbackTitle: String, isNewTabPage: Bool = false) -> StripTabItem {
        let isBrowser = tab.kind == .browser
        let isConversation = tab.kind == .conversation
        let untitled = tab.displayTitle.isEmpty || ((isBrowser || isConversation) && Self.isBlankPageAddress(tab.displayTitle))
        // A terminal its shell has not titled yet shows its folder, which the
        // shell's first title usually is, so the label does not change a
        // frame after the tab opens.
        let folder = untitled && !isBrowser && !isConversation ? tab.cwd.map(SidebarMapping.shared.abbreviate) : nil
        let title = untitled ? folder ?? fallbackTitle : isBrowser ? Self.browserTitle(tab) : tab.displayTitle
        let busy = StatusMapping.shared.loading(tab)
        var item = StripTabItem(
            id: StripTabID(tab.id),
            title: title,
            subtitle: isConversation ? nil : isBrowser ? tab.url : tab.cwd.map(SidebarMapping.shared.abbreviate),
            icon: isNewTabPage ? .icon(.tabNew) : icon(tab, isBrowser: isBrowser, isConversation: isConversation),
            isPinned: tab.pinned,
            isUnread: tab.hasUnread,
            isBusy: busy.state.isLoading || isReportingProgress(tab),
            status: status(tab)
        )
        if busy.state.replacesTabIcon { item.indicator = busy.state }
        item.busyStyle = busy.style
        applyUserIcon(tab, to: &item)
        return item
    }

    /// The icon the user set on the tab record replaces every derived icon (kind, agent
    /// mark, page icon, favicon). Callers that set a derived icon after ``item(_:fallbackTitle:isNewTabPage:)``
    /// apply it again last. A busy indicator still covers it while the tab loads.
    public func applyUserIcon(_ tab: TabModel, to item: inout StripTabItem) {
        if let icon = TabUserIcon.shared.icon(tab.userIcon) { item.icon = icon }
    }

    /// A tab's kind icon from the cmux icon registry. A live agent terminal, and an agent chat
    /// whose harness is known, wear the agent's brand mark (design/agent-icons); others, and
    /// agents without a mark, keep their kind's icon.
    func icon(_ tab: TabModel, isBrowser: Bool, isConversation: Bool) -> TabIcon {
        if isConversation {
            return AgentBrandCatalog.brand(for: tab.agentSession?.harness).map { TabIcon.agentMark($0.rawValue) } ?? .icon(.agentChat)
        }
        if isBrowser { return .icon(.browser) }
        if tab.dead { return .icon(.terminalDead) }
        if let brand = AgentBrandCatalog.brand(for: tab.agent?.agent) { return .agentMark(brand.rawValue) }
        return .icon(.terminal)
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
        // An agent chat's acpmux turn or an OSC 7501 program waits for the user.
        if StatusMapping.shared.needsInput(tab) { return .needsInput }
        // An OSC 7501 error or done the user has not seen yet.
        if let outcome = StatusMapping.shared.outcome(tab) { return outcome }
        return switch tab.agent?.state {
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

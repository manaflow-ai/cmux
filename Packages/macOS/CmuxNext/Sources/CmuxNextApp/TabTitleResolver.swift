import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextTabs

/// A tab's name wherever cmux shows it: the tab strip, the sidebar's tab
/// rows and the closed-tab toasts all read it here, so they never disagree.
/// A New Tab page is "New Tab" (or "History"), an agent chat its chat's
/// title, a Home conversation its conversation's, a page or app tab its
/// page's (a diff, Settings), never the `about:blank` address their records
/// carry. Only a browser tab with no title, or one titled with the New Tab
/// or blank page's address, falls back to "New Tab".
@MainActor
struct TabTitleResolver {
    /// Whether a tab shows the New Tab page (`RestoredNewTabPages`: one opened as it, or
    /// one restored after a relaunch that has not shown yet).
    var showsNewTabPage: @MainActor (TabModel) -> Bool
    /// A New Tab page tab's own title (`AgentHistoryPage.title`), if it has one.
    var newTabPageTitle: @MainActor (TabModel) -> String? = { _ in nil }
    /// A subagent pane's own name (``SubagentTabTitles``), nil for any other tab.
    var subagentTitle: @MainActor (TabModel) -> String? = { SubagentTabTitles.shared.title(ofTab: $0.id) }
    /// An agent chat's title before the user names it (`AgentChatTabTitle`).
    var chatTitle: @MainActor (TabModel) -> String = { AgentChatTabTitle.untitled($0.agentSession) }
    /// The name of the workspace an asked tab is in, when the caller knows it: an agent chat
    /// with no title yet reads as it (`AgentChatTabTitle`).
    var workspaceName: String?
    /// A Home conversation tab's title (`HomeService.tabTitle(for:)`).
    var conversationTitle: @MainActor (TabModel) -> String = { _ in Strings.untitledBrowser }
    /// The page an app or page tab shows, named and badged like that page.
    var page: @MainActor (TabModel) -> (title: String, icon: TabIcon)? = { _ in nil }
    /// An incognito browser tab's live title (its daemon record is a placeholder).
    var incognitoTitle: @MainActor (TabModel) -> String?? = { _ in nil }

    /// The app's live sources. `workspace`: the one workspace every asked tab is in, when the
    /// caller knows it (a pane snapshot: `RestoredNewTabPages.shows` then looks nothing up).
    init(services: AppServices, workspace: WorkspaceHandle? = nil) {
        let agentTabs = services.agentTabs
        showsNewTabPage = { [weak agentTabs] tab in agentTabs.map { RestoredNewTabPages.shows(tab, in: $0, workspace: workspace) } ?? false }
        newTabPageTitle = { [weak services] tab in services.flatMap { AgentHistoryPage.title(tab.id, $0) } }
        conversationTitle = { [weak services] tab in services?.home.tabTitle(for: tab) ?? Strings.untitledBrowser }
        page = { [weak services] tab in
            guard let services else { return nil }
            if let app = tab.appTab, let provider = services.apps.pageProvider(appID: app.app, codeRouterAsPage: false),
               let page = services.pages.storeTabItem(tab, page: provider.page) { return page }
            return tab.page != nil ? services.pages.storeTabItem(tab) : nil
        }
        incognitoTitle = { [weak services] tab in
            guard let services, tab.kind == .browser, services.cache.browserTabs.isIncognitoTab(tab.id) else { return nil }
            return .some(services.cache.incognitoDisplay(tab).title)
        }
    }

    /// The agent tabs' New Tab pages and `pages`' page tabs (tests).
    init(agentTabs: AgentTabStore, pages: InternalPageTabStore? = nil) {
        self.init(pages: pages)
        showsNewTabPage = { RestoredNewTabPages.shows($0, in: agentTabs) }
    }

    /// Fixed sources (tests).
    init(newTabPages: Set<String> = [], pages: InternalPageTabStore? = nil) {
        showsNewTabPage = { newTabPages.contains($0.id) }
        if let pages { page = { tab in tab.page != nil ? pages.storeTabItem(tab) : nil } }
    }

    /// Whether `tab` is a New Tab page (an agent tab still on that page).
    func isNewTabPage(_ tab: TabModel) -> Bool {
        tab.agentSession != nil && showsNewTabPage(tab)
    }

    /// The name `tab` shows when its program or page gave none (`fallback`
    /// for a terminal).
    func untitled(_ tab: TabModel, fallback: String = Strings.untitledTerminal) -> String {
        if tab.agentSession != nil {
            if isNewTabPage(tab) { return newTabPageTitle(tab) ?? Strings.untitledBrowser }
            // A subagent's pane is a tab on its chat's session: it shows the subagent's own name, never
            // the chat's (Leo 2026-10-30: "subagents shouldn't be tab-named the exact same as the parent").
            if let subagent = subagentTitle(tab) { return subagent }
            let title = chatTitle(tab)
            if title == AgentPaneModel.tabTitle, let name = workspaceName.flatMap(AgentChatTabTitle.taskName) { return name }
            return title
        }
        switch tab.kind {
        case .conversation: return conversationTitle(tab)
        case .browser: return Strings.untitledBrowser
        default: return fallback
        }
    }

    /// The name `tab` shows.
    func title(_ tab: TabModel) -> String {
        if let page = page(tab) { return page.title }
        if let incognito = incognitoTitle(tab) { return incognito ?? Strings.untitledBrowser }
        return TabItemMapping.shared.title(tab, fallbackTitle: untitled(tab))
    }
}

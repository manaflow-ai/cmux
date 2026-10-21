import CmuxNextAgentPane
import CmuxNextSidebar

/// The New Tab page's chats. The cards read the app's one Chats feed (acpmux's device chat index,
/// newest few). The All chats list (cx-n0i9; the sidebar has no All chats since 2026-10-10) pages
/// from the daemon on demand (`chats.page`): the socket read and decode run off the main actor,
/// and only one page of rows reaches it. Everything opens through the shared Open Chat path
/// (``ChatsOpenCoordinator``): one click a new workspace with the agent pane, Open in Terminal
/// from a row's right-click menu. Every page also gets the saved environments, which only a New
/// Tab page may read or edit (``AgentPaneEnvironmentRequest``).
@MainActor
final class AgentPageChats {
    private(set) var chats: [AgentPaneDeviceChat] = []
    /// The Recently Closed section's newest items (NewTabClosed).
    var closed: AgentPaneClosedList = .empty
    private(set) var open: (@MainActor (String) -> Void)?
    private(set) var openInTerminal: (@MainActor (String) -> Void)?
    /// View Only from a row's right-click menu (``ChatsOpenCoordinator/open(_:inTerminal:watch:replacing:)``).
    private(set) var watch: (@MainActor (String) -> Void)?
    /// A row of the New Tab page's All chats: the chat opens in that page's tab, which becomes the
    /// chat (`(chat key, page tab key)`, Lawrence 2026-10-11: "like a browser link").
    private(set) var openHere: (@MainActor (String, String) -> Void)?
    private(set) var page: ((AgentPaneChatsQuery) async -> AgentPaneChatsPage?)?
    /// This Mac's saved environments, one store for every page (AgentTabStore.wired); none in a
    /// run with no state folder, where New Tab pages list none.
    var environments: (any AgentPaneEnvironmentStoring)?

    /// Follows `feed` for every page of `tabs`; cards open through `opener`.
    static func wire(_ tabs: AgentTabStore, to feed: ChatsFeed, opener: ChatsOpenCoordinator) {
        tabs.pageChats.follow(feed, open: { [weak opener] key in opener?.open(key) }) { [weak tabs] in
            guard let tabs else { return [] }
            return Array(tabs.views.values) + tabs.standaloneViews.allObjects
        }
    }

    /// The All chats list's pages come from `environment`'s daemon; rows open through `opener`.
    static func wirePager(_ tabs: AgentTabStore, environment: AcpmuxEnvironment?, opener: ChatsOpenCoordinator) {
        let chats = tabs.pageChats
        if chats.open == nil { chats.open = { [weak opener] key in opener?.open(key) } }
        chats.openInTerminal = { [weak opener] key in opener?.openInTerminal(key) }
        chats.watch = { [weak opener] key in opener?.open(key, watch: true) }
        chats.openHere = { [weak opener] key, page in opener?.open(key, replacing: page) }
        guard let environment else { return }
        chats.page = { query in
            // One bounded page (<= AgentPaneChatsQuery.maximumLimit rows), read and decoded off the main actor.
            guard var page = try? await environment.chatsPage(query) else { return nil }
            page.design = SidebarChatsDesign.tunable.value.rawValue
            return page
        }
    }

    func follow(_ feed: ChatsFeed, open: @escaping @MainActor (String) -> Void, views: @escaping @MainActor () -> [AgentPaneView]) {
        self.open = open
        let push = { [weak self, weak feed] in
            guard let self, let feed else { return }
            chats = Self.deviceChats(feed.newest(AgentPaneDeviceChat.maximumPushed))
            for view in views() { view.deviceChats = chats }
        }
        feed.observe(self) { push() }
        push()
    }

    /// A new page starts with the current chats and closed items.
    func seed(_ view: AgentPaneView) {
        view.deviceChats = chats
        view.recentlyClosed = closed
        view.model.startFolders.environments = environments
    }

    /// The newest chats, as the page cards take them.
    static func deviceChats(_ chats: [AcpmuxChat]) -> [AgentPaneDeviceChat] {
        chats.prefix(AgentPaneDeviceChat.maximumPushed).map {
            AgentPaneDeviceChat(key: $0.id, harness: $0.harness, title: $0.title, updatedAt: $0.updatedAt)
        }
    }
}

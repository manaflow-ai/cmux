import CmuxNextAgentPane

/// The New Tab page's chat cards read the same source as the sidebar's All chats: the app's one
/// Chats feed (acpmux's device chat index). Each feed change reaches every open agent page; a
/// card opens through the shared Open Chat path (``ChatsOpenCoordinator``).
@MainActor
final class AgentPageChats {
    private(set) var chats: [AgentPaneDeviceChat] = []
    private(set) var open: (@MainActor (String) -> Void)?

    /// Follows `feed` for every page of `tabs`; cards open through `opener`.
    static func wire(_ tabs: AgentTabStore, to feed: ChatsFeed, opener: ChatsOpenCoordinator) {
        tabs.pageChats.follow(feed, open: { [weak opener] key in opener?.open(key) }) { [weak tabs] in
            guard let tabs else { return [] }
            return Array(tabs.views.values) + tabs.standaloneViews.allObjects
        }
    }

    func follow(_ feed: ChatsFeed, open: @escaping @MainActor (String) -> Void, views: @escaping @MainActor () -> [AgentPaneView]) {
        self.open = open
        let push = { [weak self, weak feed] in
            guard let self, let feed else { return }
            chats = Self.deviceChats(feed.chats)
            for view in views() { view.deviceChats = chats }
        }
        feed.observe(self) { push() }
        push()
    }

    /// The newest chats, as the page cards take them.
    static func deviceChats(_ chats: [AcpmuxChat]) -> [AgentPaneDeviceChat] {
        chats.prefix(AgentPaneDeviceChat.maximumPushed).map {
            AgentPaneDeviceChat(key: $0.id, harness: $0.harness, title: $0.title, updatedAt: $0.updatedAt)
        }
    }
}

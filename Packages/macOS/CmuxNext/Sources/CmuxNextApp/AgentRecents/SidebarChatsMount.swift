import CmuxNextDesign

/// One window's optional Chats section (`sidebar.showChats`, default off per
/// SIDEBAR-NO-RECENTS). While it is off no section exists, so the sidebar
/// never connects to the chat feed for it.
@MainActor
final class SidebarChatsMount {
    private weak var sections: SidebarAppSections?
    private var visible = false

    /// The window's app sections, with Chats when the setting is on.
    func makeSections(services: AppServices) -> SidebarAppSections {
        visible = DesignSettings.shared.sidebarSections.showChats
        let made = SidebarAppSections(registry: services.apps.registry, host: services.apps.host,
                                      recents: visible ? section(services) : nil, showsChats: visible)
        sections = made
        return made
    }

    /// Shows or hides Chats after a settings change.
    func show(_ on: Bool, services: AppServices) {
        guard on != visible else { return }
        visible = on
        sections?.setChats(on ? section(services) : nil, visible: on)
    }

    private func section(_ services: AppServices) -> AgentRecentsSection? {
        services.chatsFeed.map { feed in
            AgentRecentsSection(feed: feed) { [weak services] id in services?.chatsOpener.open(id) }
        }
    }
}

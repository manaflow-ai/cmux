import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSidebar

/// One window's All chats section (`sidebar.showChats`, on by default since
/// cx-xub5). While it is off no section exists, so the sidebar never connects
/// to the chat feed for it. A click opens the chat in a new pane to the right.
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
            let section = AgentRecentsSection(feed: feed) { [weak services] id in services?.chatsOpener.open(id, placement: .splitRight) }
            section.headerMenu = { [weak services] in services.flatMap(Self.headerMenu) }
            return section
        }
    }

    /// The header's right-click menu: the section menu with Hide Section (`SidebarHiddenSections`).
    static func headerMenu(_ services: AppServices) -> NSMenu? {
        let id = SidebarLayoutDocument.recentsSectionID
        let entries = ContextMenuCatalog.shared.entries(for: .sidebarSection,
                                                        removing: SidebarHiddenSections.headerMenuRemovals(id, isApp: true))
        return services.registry.makeContextMenu(for: .sidebarSection, target: ActionTargetRef(kind: .sidebarSection, id: id.rawValue),
                                                 entries: entries)
    }
}

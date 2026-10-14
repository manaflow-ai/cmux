import CmuxNextActions
import CmuxNextHomeEngine

/// Home as the home workspace with its left dock (classic off, cx-ebm.59.5): Home's actions open a
/// route of the docked `home-channels` page, hq-ec's page, which draws its own sheets on the daemon
/// ops (COORD.md, 2026-10-14: no Swift adapter). The host only shows Home, focuses the dock's page
/// tab and sets the page's URL hash, which the page follows (store.followHash).
extension AppActions {
    /// Page routes (hq-ec's page contract in .cmux-scratch/left-dock/COORD.md).
    enum HomeDockRoute {
        static let newMessage = "/new/message"
        static let newChief = "/new/chief"
        static let newInvite = "/new/invite"
        static func conversation(_ id: String) -> String { "/conversation/\(id)" }
    }

    /// `home.show`: the home workspace in the active window (the window that has it comes
    /// forward), else in a new window; classic Home shows its top page. False when refused.
    @discardableResult
    static func showHome(_ services: AppServices) -> Bool {
        let classic = services.home.dock.isClassic
        if classic, TopPages.show(.home, services: services) != nil { return true }
        guard !classic || services.windows.active == nil, classic || ActionRunScope.viewChangeAllowed(), let home = services.home.homeWorkspace else {
            services.registry.refuse(classic || ActionRunScope.viewChangeAllowed() ? RefusalStrings.homeNotReady : RefusalStrings.homeNeedsFocus)
            return false
        }
        if !classic, let active = services.windows.active {
            services.windows.show(workspaceID: home.id, in: active.state)
        } else {
            services.windows.reveal(workspaceID: home.id)
        }
        return true
    }

    /// Opens `route` in the docked Home page: Home shown, the dock's page tab selected with the
    /// keyboard, the page at `#<route>`. Refused (Home not ready) while the dock has no page tab yet.
    static func openDockRoute(_ route: String, _ services: AppServices) {
        guard ActionRunScope.viewChangeAllowed() else { return services.registry.refuse(RefusalStrings.homeNeedsFocus) }
        guard showHome(services) else { return }
        guard let tab = services.home.homeWorkspace.flatMap(HomeDock.pageTab(in:))?.tab,
              services.revealTab(tab.id),
              let pages = services.pages.provider(.homeChannels) as? HomeChannelsPageTab else {
            return services.registry.refuse(RefusalStrings.homeNotReady)
        }
        pages.open(route: route, tabID: tab.id, services: services)
    }
}

extension HomeService {
    /// The docked Home's workspace id (classic off), for the sidebar's Home item; nil for classic.
    var dockedHomeID: String? { dock.isClassic ? nil : homeWorkspace?.id }
}

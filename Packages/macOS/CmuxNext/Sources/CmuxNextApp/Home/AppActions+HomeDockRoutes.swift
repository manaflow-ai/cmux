import CmuxNextActions
import CmuxNextHome
import CmuxNextHomeEngine

/// Home as the home workspace with its left dock (classic off, cx-ebm.59.5): Home's actions run in
/// the dock's shown view. In Messages (the default) they do what classic Home does (the native
/// list, its sheets); in Channels they open a route of hq-ec's page, which draws its own sheets on
/// the daemon ops (COORD.md, 2026-10-14: no Swift adapter). The host only shows Home, focuses the
/// dock tab, and selects or sets the page's URL hash, which the page follows (store.followHash).
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

    /// Runs `body` on the docked Home's view: Home shown, the dock tab selected, the view made
    /// (at once, or when the tab first shows). Refused (Home not ready) while the dock has no tab yet.
    static func withDock(_ services: AppServices, _ body: @escaping @MainActor (HomeDockView) -> Void) {
        guard ActionRunScope.viewChangeAllowed() else { return services.registry.refuse(RefusalStrings.homeNeedsFocus) }
        guard showHome(services) else { return }
        guard let tab = services.home.homeWorkspace.flatMap(HomeDock.pageTab(in:))?.tab,
              services.revealTab(tab.id),
              let provider = services.pages.provider(.homeDock) as? HomeDockTab else {
            return services.registry.refuse(RefusalStrings.homeNotReady)
        }
        provider.whenShown(tab.id, services: services, body)
    }

    /// Opens `route` in the docked Home: in Channels the page goes to `#<route>`; in Messages
    /// `messages` runs on the native view instead (the classic sheet, the list selection).
    static func openDockRoute(_ route: String, _ services: AppServices, messages: @escaping @MainActor (TopHomePageView) -> Void) {
        withDock(services) { dock in
            if dock.mode == .messages, let page = dock.messages {
                messages(page)
            } else {
                dock.open(route: route)
                dock.focusPrimaryInput()
            }
        }
    }

    /// Opens `route` in the docked Home's Channels page, switching to Channels from Messages
    /// first: New Chief is a page there (u2586), never the Messages sheet. `messages` runs only
    /// while Channels is off.
    static func openChannelsRoute(_ route: String, _ services: AppServices, messages: @escaping @MainActor (TopHomePageView) -> Void) {
        withDock(services) { dock in
            guard dock.mode == .messages else {
                dock.open(route: route)
                return dock.focusPrimaryInput()
            }
            guard HomeDockView.Mode.channels.isEnabled else {
                if let page = dock.messages { messages(page) }
                return
            }
            dock.switchTo(.channels)
            // task-owner: one wait for the switch in flight (bounded by its selection deadline), then the route
            // main-hop-allow: userBlocking rest of the person's action (p06 rule 2): it awaits the main-actor dock switch; post has no userBlocking class
            Task { @MainActor [weak dock] in
                await dock?.settled()
                dock?.open(route: route)
                dock?.focusPrimaryInput()
            }
        }
    }

    /// `home.switchView {view?}`: selects the sidebar's Home entry (`messages`) or Channels entry
    /// (`channels`, the other one when absent): the docked Home shows that view, with the selection
    /// handed over. The one path of the sidebar's Channels entry, the palette, the CLI and MCP. Refused
    /// for Channels while it is off, and in classic Home (one view).
    static func switchHomeView(_ services: AppServices, _ invocation: ActionInvocation) {
        guard !services.home.dock.isClassic else { return services.registry.refuse(HomeDockMode.classicMessage) }
        let named = invocation["view"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let view = named.flatMap(HomeDockView.Mode.init(rawValue:))
        guard named == nil || view != nil else { return services.registry.refuse(HomeDockMode.invalidViewMessage) }
        let target = view ?? services.home.dockMode.other
        guard target.isEnabled else { return services.registry.refuse(HomeDockMode.channelsOffMessage) }
        withDock(services) { $0.switchTo(target) }
    }
}

extension HomeService {
    /// The docked Home's workspace id (classic off), for the sidebar's Home item; nil for classic.
    var dockedHomeID: String? { dock.isClassic ? nil : homeWorkspace?.id }
}

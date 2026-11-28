import CmuxNextActions
import CmuxNextBrowser
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import CmuxNextSidebar
import Foundation

/// The one path that opens a top page (TOP-SECTION-ITEMS-ARE-PAGES): the
/// sidebar's top items, Cmd-1, `home.show` and `appStore.show` all come
/// here. A run without view-change permission (automation) shows nothing.
@MainActor
enum TopPages {
    /// Shows `route` in `state`'s window (else the active window) and gives
    /// the page the keyboard. Returns the provider key of an internal
    /// page's view (the App Store routes its listing through it), "" for
    /// Home, nil when nothing was shown.
    @discardableResult
    static func show(_ route: TopPageRoute, services: AppServices, in state: WindowState? = nil) -> String? {
        guard ActionRunScope.viewChangeAllowed(),
              let controller = state.flatMap({ services.windows.controller(for: $0.id) }) ?? services.windows.active else { return nil }
        guard controller.topPages.view(for: route, in: controller) != nil else { return nil }
        let origin = controller.trailOrigin
        if controller.state.page != route {
            controller.state.page = route
            services.windows.recordSaver.stateDidChange(controller.state)
        }
        controller.showTopPage(route)
        controller.topPages.focus(route, in: controller.window)
        services.locationTrail.pageDidShow(route, title: controller.topPages.title(for: route), origin: origin, in: controller)
        if case .home = route { return "" }
        return controller.topPages.key(for: route)
    }

    /// The registry's top-page rules (`ActionTopPageRules`): a run on an existing tab that names
    /// none refuses while the active window shows a page (TOP-SECTION-ITEMS-ARE-PAGES Q1); a
    /// person's New Tab, New Terminal Tab or split leaves the page and runs in the workspace.
    static func installActionRules(_ services: AppServices) {
        services.registry.install(ActionTopPageRules(isShowing: { [weak services] in services?.windows.active?.shownTopPage != nil },
                                                     canLeave: { [weak services] in services?.windows.active?.leavingShowsWorkspace == true },
                                                     leave: { [weak services] in _ = services?.windows.active?.leaveTopPage() },
                                                     noTabs: { RefusalStrings.topPageHasNoTabs }, noPanes: { RefusalStrings.topPageHasNoPanes }))
    }

    /// Leaves the active window's top page for its workspace at once (a
    /// History or Bookmarks row opens there). True when a page was left.
    @discardableResult
    static func leave(_ services: AppServices) -> Bool { services.windows.active?.leaveTopPage() ?? false }

    private static func registerFlagged(_ provider: WebPageTab, action: ActionID, services: AppServices, reason: String, shows: @escaping (CmuxConfigSnapshot) -> Bool) {
        services.pages.register(provider)
        services.registry.addSettingOffReason([action]) { [weak services] in services?.settings.map { shows($0.snapshot) } == true ? nil : reason }
        _ = services.registry.bindEffect(action, effect: { [weak services, page = provider.page] _ in _ = services.map { TopPages.show(.page(page), services: $0) }; return .done })
    }

    /// The pages History and Bookmarks show on top (Q3).
    static func registerProviders(_ services: AppServices) {
        services.pages.register(HistoryTopPage(services: services))
        services.pages.register(BookmarksTopPage(services: services))
        services.pages.register(StashTopPage(services: services))
        // Forum and Feed (experiments.forum, experiments.feed, off by default; the Feed: every update, ask c-9f58e14079): `action` opens it, hidden and refused with `reason` while `shows` is false.
        registerFlagged(WebPageTab(.forum, symbol: SidebarBuiltIn.forum.symbol, icon: SidebarBuiltIn.forum.icon, title: SidebarBuiltIn.forum.title) { [weak services] in services.flatMap { s in
            PageWebView(descriptor: .forum, routes: [PageRoute(prefix: "cmux.forum.", provider: DaemonPageRelay(services: s))], route: nil).map { page -> PageWebView in PageConnectionWatch(page: page, store: s.machines.local.store).start(); return page } } }, action: "forum.show", services: services, reason: CmuxConfigSnapshot.forumHiddenReason) { $0.showsForum }
        registerFlagged(WebPageTab(.feed, symbol: SidebarBuiltIn.feed.symbol, title: SidebarBuiltIn.feed.title) { [weak services] in services.flatMap { PageFactory(services: $0).feedWebPage(route: "#/inbox") } }, action: "feed.show", services: services, reason: CmuxConfigSnapshot.feedHiddenReason) { $0.showsFeed }
        // Automations (docs/automations-platonic-ideal.md section 8): this Mac's store through the bundled CLI, Cloud through cloud.automation.
        let automations = AutomationsPageHost(bundled: services.bundledCLI, cloud: { [forward = CloudCLICall(cli: services.bundledCLI).automationRelay(signedIn: services.cloud.auth)] in
            try AutomationsPageHost.cloudValue(await forward(Data(#"{"op":"automation.list","params":{"limit":100}}"#.utf8))) })
        automations.openChat = { [weak services] session, title in // a prompt run's chat, found by its name
            _ = services?.registry.perform("agent.openSessionWorkspace", invocation: .init(arguments: ["session": .string(session), "name": .string(title)], origin: .user))
        }
        // Signed out, the page's Cloud line offers the app's one cmux sign-in (msg 3790), saying what it signs in to.
        automations.signIn = { [weak services] in services.map { app in CmuxSignInOffer(registry: app.registry, isSignedIn: { app.cloud.isSignedIn }).signIn() } }
        automations.signInBackend = services.cloud.configuration.signInBackendLine
        services.pages.register(WebPageTab(.automations, symbol: "clock.badge.checkmark", icon: .automation, title: SidebarBuiltIn.automations.title,
                                           view: { [weak services] _ in let scope = services?.windows.active?.themeScope ?? .app; return automations.makeView(tokens: { [weak scope] in scope?.tokens ?? ThemeScope.app.tokens }) }))
        _ = services.registry.bindEffect("automations.show", effect: { [weak services] i in _ = services.map { TopPages.show(.page(.automations), services: $0) }; automations.show(named: i.arguments["name"]?.stringValue); return .done })
    }

    /// The bookmarks profile of a Bookmarks top page: the browser profile
    /// of the window's current workspace (its last-focused browser tab),
    /// else the default profile.
    static func bookmarkProfile(of window: WindowController, services: AppServices) -> String {
        guard let tab = bookmarkTab(of: window, services: services) else { return BrowserProfileRecord.defaultID }
        return services.bookmarks.profile(ofTab: tab)
    }

    /// The browser tab whose profile the window's workspace uses: the
    /// selected browser tab of the most recently focused pane, else any
    /// browser tab of the workspace, most recently focused panes first.
    static func bookmarkTab(of window: WindowController, services: AppServices) -> String? {
        guard let id = window.state.workspaceID, let (workspace, _) = services.machines.workspace(id: id) else { return nil }
        let panes = workspace.screens.flatMap(\.panes)
        let recent = (window.focus.recentPanes(in: id)).compactMap { key in panes.first { $0.id == key } }
        let ordered = recent + panes.filter { pane in !recent.contains { $0 === pane } }
        for pane in ordered {
            if let selected = window.state.selection.selection(in: pane.id),
               let tab = pane.tabs.first(where: { $0.id == selected }), tab.kind == .browser { return tab.id }
        }
        return ordered.lazy.flatMap(\.tabs).first { $0.kind == .browser }?.id
    }

    /// The provider of internal page `id`: a registered one, else an app's
    /// page registered on first use (`app:<id>` pages).
    static func provider(_ id: InternalPageID, services: AppServices) -> (any InternalPageProvider)? {
        if let provider = services.pages.provider(id) { return provider }
        let prefix = AppPanePage.pageID("").rawValue
        guard id.rawValue.hasPrefix(prefix) else { return nil }
        return services.apps.pageProvider(appID: String(id.rawValue.dropFirst(prefix.count)))
    }
}

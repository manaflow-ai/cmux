import CmuxNextActions
import CmuxNextBrowser
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextDaemon
import CmuxNextDesign
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

    /// Actions on an existing tab (Close Tab, Cmd-W) refuse while the active
    /// window shows a top page and the run names no tab: pages have no tabs
    /// and do not close (TOP-SECTION-ITEMS-ARE-PAGES Q1). The refusal makes
    /// `perform` report the run as not ran, so debug.key and menus agree.
    static func installTabTargetReasons(_ services: AppServices) {
        let registry = services.registry
        for descriptor in registry.descriptors where descriptor.targets == [.tab] {
            let previous = registry.action(for: descriptor.id)?.targetUnavailableReason
            ActionTargetReasons.set(descriptor.id, in: registry) { [weak services] invocation in
                if let reason = previous?(invocation) { return reason }
                guard invocation.target == nil, invocation["tab"] == nil,
                      services?.windows.active?.shownTopPage != nil else { return nil }
                return RefusalStrings.topPageHasNoTabs
            }
        }
    }

    /// Leaves the active window's top page for its workspace at once (a
    /// History or Bookmarks row opens there). True when a page was left.
    @discardableResult
    static func leave(_ services: AppServices) -> Bool {
        services.windows.active?.leaveTopPage() ?? false
    }

    /// The pages History and Bookmarks show on top (Q3).
    static func registerProviders(_ services: AppServices) {
        services.pages.register(HistoryTopPage(services: services))
        services.pages.register(BookmarksTopPage(services: services))
        services.pages.register(StashTopPage(services: services))
        // Automations (docs/automations-platonic-ideal.md section 8): this Mac's store through the bundled CLI, Cloud through cloud.automation.
        let automations = AutomationsPageHost(local: { [bundled = services.bundledCLI] in
            guard let cli = await bundled.resolve() else { throw AutomationsPageHost.SourceError(code: "no_cli", message: "") }
            let listed = try await ProcessRunner.run(executable: cli, arguments: ["--json", "automation", "list"], environment: nil, timeout: .seconds(10), clock: ContinuousClock())
            guard listed.status == 0 else { throw AutomationsPageHost.SourceError(code: "cli_failed", message: String(decoding: listed.stderr, as: UTF8.self)) }
            return listed.stdout
        }, cloud: { [relay = CloudAutomationRelay.signedIn(services.cloud.auth)] in
            try AutomationsPageHost.cloudValue(await relay.forward(Data(#"{"op":"automation.list","params":{"limit":100}}"#.utf8))) })
        services.pages.register(WebPageTab(.automations, symbol: "clock.badge.checkmark", icon: .automation, title: SidebarBuiltIn.automations.title,
                                           view: { [weak services] _ in let scope = services?.windows.active?.themeScope ?? .app; return automations.makeView(tokens: { [weak scope] in scope?.tokens ?? ThemeScope.app.tokens }) }))
        _ = services.registry.bindEffect("automations.show", effect: { [weak services] _ in _ = services.map { TopPages.show(.page(.automations), services: $0) }; return .done })
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
    /// page registered on first use (CodeRouter, `app:<id>` pages).
    static func provider(_ id: InternalPageID, services: AppServices) -> (any InternalPageProvider)? {
        if let provider = services.pages.provider(id) { return provider }
        if id == .coderouter { return services.apps.pageProvider(appID: CodeRouterPageTab.appID) }
        let prefix = AppPanePage.pageID("").rawValue
        guard id.rawValue.hasPrefix(prefix) else { return nil }
        return services.apps.pageProvider(appID: String(id.rawValue.dropFirst(prefix.count)))
    }
}

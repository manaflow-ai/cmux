import CmuxNextAccounts
import CmuxNextActions
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// Builds the app's React pages with their routes (its own type, not an `AppServices` member:
/// that type's line budget is frozen).
@MainActor
struct PageFactory {
    unowned let services: AppServices

    /// The React History page when Debug Settings `history.surface` is `web`, else nil (the
    /// Swift page). The tunable goes when the React page becomes the default (react-pages.md H3).
    func historyWebPage() -> PageWebView? {
        guard PageTunables.history.value == .web else { return nil }
        let routes = pageRoutes(for: .history)
        guard let page = services.pageHostPool.claim(.history, routes: routes,
                                                      window: services.windows.active?.window, focus: false)
            ?? PageWebView(descriptor: .history, routes: routes) else { return nil }
        PageConnectionWatch(page: page, store: services.machines.local.store).start()
        return page
    }

    /// The React App Store page (react-pages.md 3) on `route` (`#/discover?app=<id>`,
    /// `#/installed`) when Debug Settings `apps.store.surface` is `web`, else nil (the Swift
    /// store). `cmux.apps.` goes to the daemon relay behind the native sheet of
    /// ``AppsPageConfirmations``; the sheet reads the listing first so it can name the scopes.
    func appsWebPage(route: String?) -> PageWebView? {
        guard PageTunables.appStore.value == .web else { return nil }
        let relay = DaemonPageRelay(services: services)
        let confirming = ConfirmingPageProvider(inner: relay, presenter: DialogPageConfirmationPresenter()) { op, params in
            guard AppsPageConfirmations.needsDetail(op), let app = params["app"]?.stringValue else { return nil }
            let detail = try? await relay.call("cmux.apps.catalog.get", params: ["app": .string(app)],
                                               context: PageCallContext(page: PageDescriptor.apps.id))
            return AppsPageConfirmations.confirmation(op: op, params: params, detail: detail)
        }
        let native = AppPageNativeProvider(services: services, page: .apps)
        let routes = [PageRoute(prefix: "cmux.apps.", provider: confirming), PageRoute(prefix: "cmux.app.", provider: native)]
        guard let page = PageWebView(descriptor: .apps, routes: routes, route: route) else { return nil }
        confirming.anchor = { [weak page] in page }
        native.anchor = { [weak page] in page }
        PageConnectionWatch(page: page, store: services.machines.local.store).start()
        return page
    }

    /// The React CodeRouter page (cmux.coderouter). Its namespace goes to the CodeRouter app's
    /// ops over the control router (``CodeRouterPageProvider``); before the control socket starts
    /// every call answers `unavailable`. `cmux.app.` runs the page's four account actions.
    func coderouterWebPage() -> PageWebView? {
        let ops = CodeRouterAppOps(control: { [weak apps = services.apps] method, params throws(AppHostCapabilityError) in
            guard let router = await MainActor.run(body: { apps?.controlRouter }) else {
                throw AppHostCapabilityError(code: "unavailable", message: "cmux is still starting", retryable: true)
            }
            return try await AppOperationRouter.control(router, method, params)
        })
        let registry = services.registry
        let provider = CodeRouterPageProvider(ops: ops, connect: { id in
            registry.perform(ActionID(rawValue: "accounts.connect"), invocation: ActionInvocation(arguments: ["provider": .string(id)], origin: .user))
        })
        let confirming = ConfirmingPageProvider(inner: provider, presenter: DialogPageConfirmationPresenter()) { op, params in
            CodeRouterPageConfirmations.confirmation(op: op, params: params)
        }
        let native = AppPageNativeProvider(services: services, page: .coderouter)
        let routes = [PageRoute(prefix: "cmux.coderouter.", provider: confirming), PageRoute(prefix: "cmux.app.", provider: native)]
        guard let page = PageWebView(descriptor: .coderouter, routes: routes) else { return nil }
        confirming.anchor = { [weak page] in page }
        native.anchor = { [weak page] in page }
        return page
    }

    /// The Cloud app page (cmux.cloud) with the machine list layout from Debug Settings. Its
    /// namespace answers "not available yet" until the app supervisor (apps-v1) runs the Cloud app
    /// server; then the route goes to the supervisor relay.
    func cloudWebPage() -> PageWebView? {
        let native = AppPageNativeProvider(services: services, page: .cloud)
        let cloud = UnavailablePageProvider(code: "cmux.cloud.unsupported")
        native.forward = { op, params, context in try await cloud.call(op, params: params, context: context) }
        let routes = [PageRoute(prefix: "cmux.cloud.", provider: cloud), PageRoute(prefix: "cmux.app.", provider: native)]
        let attributes = ["cloud-machines-layout": PageTunables.cloudMachinesLayout.value.rawValue]
        let page = services.pageHostPool.claim(.cloud, routes: routes,
                                               documentAttributes: attributes,
                                               window: services.windows.active?.window, focus: false)
            ?? PageWebView(descriptor: .cloud, routes: routes, documentAttributes: attributes)
        native.anchor = { [weak page] in page }
        if let page { PageConnectionWatch(page: page, store: services.machines.local.store).start() }
        return page
    }

    /// The React Settings page (R82) on `route` (`#/settings/<section>?focus=<key>`). Its namespace
    /// goes to `SettingsPageProvider` (interim owner; the daemon relay once the config actor
    /// serves `settings.*`), `cmux.app.` to the native ops.
    func settingsPage(route: String?) -> PageWebView? {
        guard let settings = services.settings else { return nil }
        let provider = SettingsPageProvider(settings: settings, domains: { [weak services] in
            ["themes": services?.themes?.catalog.names ?? [], "font_families": SettingsPageDomains.fontFamilies, "sounds": SettingsPageDomains.sounds]
        }, hostLists: { [weak services] in services?.settingsWindow.pageHostLists() ?? .null })
        let accounts = services.accounts.model
        provider.accountsState = { (try? JSONValue.parse(JSONEncoder().encode(accounts.pageState))) ?? .null }
        provider.accountsRun = { params in
            guard let action = AccountsPageAction(action: params["action"]?.stringValue ?? "", provider: params["provider"]?.stringValue,
                                                  account: params["account"]?.stringValue, secret: params["secret"]?.stringValue) else {
                throw PageError.invalidParams("unknown accounts action")
            }
            if let error = await accounts.perform(action) { return ["error": .string(error)] }
            return .object([:])
        }
        provider.setTheme = { [weak services] level, spec in try services?.settingsWindow.setPageTheme(level: level, spec: spec) }
        provider.acceptsTheme = { [weak services] text in services?.settingsWindow.acceptsTheme(text) ?? false }
        let registry = services.registry
        provider.sectionActions = { section in
            .array(SettingsSchema.actions(in: section).compactMap { id in
                guard let descriptor = registry.descriptor(for: id) else { return nil }
                return ["id": .string(id.rawValue), "title": .string(descriptor.title),
                        "enabled": .bool(registry.isAvailable(id))]
            })
        }
        provider.pickFolders = { [weak services] in
            guard let urls = await services?.viewers.picker.open(.init(choose: .folders, allowsMultiple: true)) else { return nil }
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
            return urls.map { url in
                let path = url.standardizedFileURL.path
                // Inside home: `~/…` (the schema accepts absolute or `~/` paths); home itself stays absolute.
                return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
            }
        }
        let native = AppPageNativeProvider(services: services, page: .settings)
        let routes = [PageRoute(prefix: "cmux.settings.", provider: provider), PageRoute(prefix: "cmux.app.", provider: native)]
        // `appearance.surfaces.settings` colors the page, as it colored the Swift Settings view.
        let dynamicResources = SettingsBackdropThumbnails(choices: SettingsWindowService.backdrops.choices)
        let page = services.pageHostPool.claim(.settings, routes: routes, route: route, surface: .settings,
                                               dynamicResources: dynamicResources,
                                               window: services.windows.active?.window, focus: false)
            ?? PageWebView(descriptor: .settings, routes: routes, route: route, surface: .settings,
                           dynamicResources: dynamicResources)
        native.anchor = { [weak page] in page }
        return page
    }

    /// The routes of `page`: its namespaces to the daemon relay, `cmux.app.` to the native ops
    /// (whose confirmed ops run on the namespace relay after the sheet).
    func pageRoutes(for page: PageDescriptor) -> [PageRoute] {
        let relay = DaemonPageRelay(services: services)
        let native = AppPageNativeProvider(services: services, page: page)
        native.forward = { op, params, context in try await relay.call(op, params: params, context: context) }
        return page.namespaces.map { PageRoute(prefix: $0, provider: relay) } + [PageRoute(prefix: "cmux.app.", provider: native)]
    }
}

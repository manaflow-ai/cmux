import AppKit
import CmuxNextApps
import CmuxNextControl
import CmuxNextIcons
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// App platform in the App (plans/cmux-next/app-platform.md section 13):
/// the client of the local daemon's app supervisor (`apps-v1`). The
/// supervisor owns installs, grants, storage and the app hosts; this service
/// mirrors them (`client`), serves the Mac-side app op families over the
/// provider channel once the control router exists, and owns the App
/// Store's and the app pages' tabs. Nothing here runs app code.
@MainActor
final class AppsService {
    unowned let services: AppServices
    let transport: DaemonAppsTransport
    let client: AppsClient
    /// The control router once the socket starts (the CodeRouter page's ops run on it).
    private(set) var controlRouter: ControlRouter?
    /// The React CodeRouter page tab (Debug Settings `coderouter.surface = web`), registered on first open.
    private var coderouterPage: CodeRouterPageTab?
    /// An App Store request made while no main window could hold it (S22:
    /// the App Store is never a window of its own); the first window that
    /// mounts a pane shows it (`windowDidShowContent`).
    private var waitingStore: (appID: String?, installed: Bool, focus: Bool)?
    var isStoreWaiting: Bool { waitingStore != nil }
    /// App pages (`app:<id>`), one provider per app, registered on first open.
    private var appPages: [String: AppPanePage] = [:]
    /// The React App Store page per tab (Debug Settings `apps.store.surface = web`), else empty.
    private var webStorePages: [String: PageWebView] = [:]
    /// The App Store tabs (internal page), one store model per tab over the
    /// one client. Captures the client, not the service, so a page set that
    /// outlives the service still makes models.
    private(set) lazy var storePages = AppStorePages { [weak self, client = self.client] in
        let model = AppStoreModel(client: client)
        model.onNavigate = { self?.services.locationTrail.pageHistoryDidChange() }
        return model
    }

    init(services: AppServices) {
        self.services = services
        transport = DaemonAppsTransport(daemon: services.daemon)
        client = AppsClient(transport: transport)
    }

    /// Turning apps off (DisabledFeatures) makes the supervisor unreachable
    /// from this Mac: nothing mounts, every change is refused, and open app
    /// sections and pages show "Turned off by your organization".
    func applyPolicy(disabled: Bool) {
        transport.turnedOff = disabled ? RefusalStrings.turnedOffByOrganization : nil
    }

    /// What the local daemon's supervisor needs from this app at launch: the
    /// first-party app packages shipped in the app bundle (its default apps).
    nonisolated static var daemonEnvironment: [String: String] {
        ["CMUX_APPS_FIRST_PARTY_DIR": AppPlatformResources.firstParty.path]
    }

    func start() {
        client.start()
        // task-owner: one off-main load of the bundled package directories and the scope table at launch
        Task { await AppPlatformResources.preload() }
    }

    /// Serves the Mac-side app op families (`coderouter`, `action`) on the
    /// control router through the supervisor's provider channel.
    func attach(router: ControlRouter) {
        controlRouter = router
        let control: @Sendable (String, [String: JSONValue]) async throws(AppHostCapabilityError) -> JSONValue = { method, params throws(AppHostCapabilityError) in
            try await router.appControl(method, params)
        }
        transport.provider.attach(AppHostCapabilities([CodeRouterAppOps(control: control), ActionAppOps(control: control)]))
    }

    /// Opens the App Store (palette "App Store", `appStore.show`): a user
    /// run shows it as the active window's App Store top page
    /// (TOP-SECTION-ITEMS-ARE-PAGES); automation, which never changes the
    /// view, opens it as a background tab (internal page `app-store`, one
    /// per window). `appID` opens that listing, `installed` the Installed
    /// tab. With no main window that can hold it, the request waits for
    /// one (a closed window comes back, or a new one opens), as Settings
    /// does: S22, the App Store never opens a window of its own.
    func showStore(appID: String? = nil, installed: Bool = false, focus: Bool = true) {
        let key = focus ? TopPages.show(.page(.appStore), services: services)
            : services.pages.show(.appStore, in: services.windows.active, focus: false)?.key
        if let key {
            if let page = webStorePages[key] {
                page.open(route: Self.storeRoute(appID: appID, installed: installed))
            } else {
                storePages.present(key, appID: appID, installed: installed)
            }
            waitingStore = nil
            return
        }
        waitingStore = (appID, installed, focus)
        if case let windows = services.windows, windows.restored, windows.controllers.isEmpty { windows.reopenOrCreateWindow() }
    }

    /// The first window opened or a window mounted a pane: a request that
    /// waited runs again (a user run shows the top page as soon as a window
    /// exists; an automation run still waits until a pane can hold its tab).
    func windowDidShowContent() {
        guard let request = waitingStore else { return }
        showStore(appID: request.appID, installed: request.installed, focus: request.focus)
    }

    /// Opens an app's page as a tab of the active window (one per window),
    /// then runs `command` (one of the app's palette ops, by name or its last
    /// segment, for example CodeRouter's connectAccount) in the app when
    /// given. User runs select and
    /// focus the tab; automation opens it without moving focus.
    func openApp(_ appID: String, command: String? = nil, focus: Bool = true) throws(AppsServiceError) {
        guard let app = client.app(appID), app.isActive else { throw .unknownApp }
        let codeRouter = appID == CodeRouterPageTab.appID && PageTunables.coderouter.value == .web
        if codeRouter, command == nil, let provider = pageProvider(appID: appID) {
            guard services.pages.show(provider.page, in: services.windows.active, focus: focus) != nil else { throw .noWindow }
            return
        }
        guard AppPanePage.opens(app), let provider = pageProvider(appID: appID, codeRouterAsPage: false) else { throw .noPage }
        guard services.pages.show(provider.page, in: services.windows.active, focus: focus) != nil else { throw .noWindow }
        if let command {
            guard let found = app.commands.first(where: { AppCommandPalette.Entry(app: app, command: $0).matches(command) }) else {
                throw .unknownCommand
            }
            AppCommandPalette.run(AppCommandPalette.Entry(app: app, command: found), services: services)
        }
    }

    /// The page provider of app `appID` (registered on first use): CodeRouter's
    /// web page, else the app's own pane page; nil when the app has no page.
    func pageProvider(appID: String, codeRouterAsPage: Bool = true) -> (any InternalPageProvider)? {
        if codeRouterAsPage, appID == CodeRouterPageTab.appID, PageTunables.coderouter.value == .web {
            let tab = coderouterPage ?? CodeRouterPageTab(services: services)
            if coderouterPage == nil {
                coderouterPage = tab
                services.pages.register(tab)
            }
            return tab
        }
        guard let app = client.app(appID), app.isActive, AppPanePage.opens(app) else { return nil }
        let provider = appPages[appID] ?? AppPanePage(appID: appID, apps: self)
        if appPages[appID] == nil {
            appPages[appID] = provider
            services.pages.register(provider)
        }
        return provider
    }
}

// MARK: InternalPageProvider (the App Store as a tab)

extension InternalPageID {
    static let appStore = InternalPageID(rawValue: "app-store")
}

extension AppsService: InternalPageProvider {
    var page: InternalPageID { .appStore }
    var title: String { AppStoreModel.title }
    var symbol: String { "bag" }
    var icon: IconName? { .store }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        if let page = PageFactory(services: services).appsWebPage(route: Self.storeRoute(appID: nil, installed: false)) {
            webStorePages[key] = page
            return page
        }
        return storePages.makeView(for: key)
    }

    func tabClosed(_ key: String) {
        webStorePages.removeValue(forKey: key)?.close()
        storePages.tabClosed(key)
    }

    /// The native store's page history (the React store keeps its own).
    func history(for key: String) -> (any PageHistory)? {
        webStorePages[key] == nil ? storePages.model(for: key) : nil
    }

    /// The React page's fragment for a listing or the Installed tab.
    nonisolated static func storeRoute(appID: String?, installed: Bool) -> String {
        if installed { return "#/installed" }
        guard let appID, var query = URLComponents(string: "x:") else { return "#/discover" }
        query.queryItems = [URLQueryItem(name: "app", value: appID)]
        return "#/discover?" + (query.percentEncodedQuery ?? "")
    }
}

enum AppsServiceError: Error {
    case unknownApp, noPage, noWindow, unknownCommand
}


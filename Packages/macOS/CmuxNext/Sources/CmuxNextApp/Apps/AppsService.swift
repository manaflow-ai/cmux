import struct CmuxSafeConcurrency.OwnerReference
import AppKit
import CmuxNextActions
import CmuxNextApps
import CmuxNextControl
import CmuxNextDaemonService
import CmuxNextHibernation
import CmuxNextIcons
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// App platform in the App (plans/cmux-next/app-platform.md section 13):
/// the client of the local daemon's app supervisor (`apps-v1`). The
/// supervisor owns installs, grants, storage and the app hosts; this service
/// mirrors them (`client`), serves the Mac-side app op families over the
/// provider channel once the control router exists, and owns the App
/// Store's and the app pages' tabs. Nothing here runs app code.
@MainActor
final class AppsService {
    private let servicesReference: OwnerReference<AppServices>
    /// The app's services, which own this; nil (reported) only once they are gone.
    var services: AppServices? { servicesReference.resolve() }
    let transport: DaemonAppsTransport
    let client: AppsClient
    /// The control router once the socket starts (the CodeRouter page's ops run on it).
    private(set) var controlRouter: ControlRouter?
    /// The React CodeRouter page tab (Debug Settings `coderouter.surface = web`), registered on first open.
    private var coderouterPage: WebPageTab?
    /// An App Store request made while no main window could hold it (S22:
    /// the App Store is never a window of its own); the first window that
    /// mounts a pane shows it (`windowDidShowContent`).
    private var waitingStore: (appID: String?, tab: AppStoreTab?, focus: Bool)?
    var isStoreWaiting: Bool { waitingStore != nil }
    /// App pages (`app:<id>`), one provider per app, registered on first open.
    private var appPages: [String: AppPanePage] = [:]
    /// The App Store page (React, apps-web-DESIGN.md) per tab key.
    private var webStorePages: [String: PageWebView] = [:]
    /// The place each hidden App Store tab's page showed when its discard read it.
    private var shownPlaces: [String: (version: Int, fragment: String?)] = [:]
    /// The place each discarded App Store tab showed, for the page its next show makes.
    private var discardedRoutes: [String: String] = [:]
    /// The route each show asked for, for the page of the tab it opened or selected (``makeView(for:in:)``).
    private let storeOpens = PageOpenRequests<String>()
    private var machineCatalog: MachineCatalogPublisher?
    /// Makes an App Store tab's page on a route (default: ``PageFactory/appsWebPage(route:)``;
    /// tests pass their own engine).
    private let makeStorePage: ((String) -> PageWebView?)?

    init(services: AppServices, makeStorePage: ((String) -> PageWebView?)? = nil) {
        servicesReference = OwnerReference(services: services)
        self.makeStorePage = makeStorePage
        transport = DaemonAppsTransport(daemon: services.daemon, mainWork: services.mainWork, inventoryRoutes: { [weak machines = services.machines] in
            machines?.agentInventoryWatchRoutes() ?? []
        })
        client = AppsClient(transport: transport, bundleImages: AppBundleImageCache())
        AppMemoryConsumers(services: services).registerAppBundleImages(client.bundleImages)
    }

    /// Turning apps off (DisabledFeatures) makes the supervisor unreachable
    /// from this Mac: every mount ends on the supervisor, nothing mounts,
    /// every change is refused, and open app sections and pages show
    /// "Turned off by your organization".
    func applyPolicy(disabled: Bool) {
        // The mounts end on the supervisor first (in order on the client's chain); a reconnect remounts them.
        if disabled, transport.turnedOff == nil { client.suspendMounts() }
        transport.turnedOff = disabled ? RefusalStrings.turnedOffByOrganization : nil
    }

    func start() {
        guard let services else { return }
        client.start()
        let client = client, mainWork = services.mainWork
        // task-owner: one off-main load of the bundled package directories and the scope table at launch. R-hop: read
        // off main; the client takes them in one visible task (app icons draw from them).
        services.work.task(.userVisible) {
            let directories = await AppPlatformResources.bundledDirectories()
            mainWork.postFromAnyThread(.visible, owner: "AppsService.bundledDirectories") { client.useBundledDirectories(directories) }
        }
    }

    /// Serves app-side operations, admitted machine inventory reads and the
    /// Agent Memory app's search through the supervisor's verified-app provider channel.
    func attach(router: ControlRouter) {
        guard let services else { return }
        controlRouter = router
        let control: @Sendable (String, [String: JSONValue]) async throws(AppHostCapabilityError) -> JSONValue = { method, params throws(AppHostCapabilityError) in try await router.appControl(method, params) }
        let inventory = AgentCLICapabilityHandler { [weak machines = services.machines] in
            machines?.agentInventoryRoutes() ?? []
        }
        let actionControl: @Sendable (String, [String: JSONValue], String) async throws(AppHostCapabilityError) -> JSONValue = { method, params, app throws(AppHostCapabilityError) in try await router.appControl(method, params, callerApp: app) }
        // The Agent Memory app's search, from the agent memory index while `agents.memory.enabled` is on.
        let memory = AgentMemorySearchHandler(enabled: { [weak services] in
            services?.settings?.snapshot.agentMemoryEnabled ?? false
        }, index: BundledAgentMemoryIndex.bundled())
        transport.provider.attach(AppHostCapabilities([CodeRouterAppOps(control: control), ActionAppOps(control: actionControl), inventory, memory]))
        if machineCatalog == nil {
            machineCatalog = MachineCatalogPublisher(source: { [weak machines = services.machines] in
                machines?.catalogSource()
            }, on: services.mainWork)
            machineCatalog?.start()
        }
    }

    /// Opens the App Store (palette "App Store", `appStore.show`): a user
    /// run shows it as the active window's App Store top page
    /// (TOP-SECTION-ITEMS-ARE-PAGES); automation, which never changes the
    /// view, opens it as a background tab (internal page `app-store`, one
    /// per window). `appID` opens that listing, `tab` a store tab (Discover,
    /// Installed). With no main window that can hold it, the request waits for
    /// one (a closed window comes back, or a new one opens), as Settings
    /// does: S22, the App Store never opens a window of its own.
    func showStore(appID: String? = nil, tab: AppStoreTab? = nil, focus: Bool = true) {
        guard let services, services.settings?.snapshot.previewFeatures == true else { return }
        let route = Self.storeRoute(appID: appID, tab: tab)
        let key: String?
        if focus {
            key = storeOpens.during(route) { TopPages.show(.page(.appStore), services: services) }
        } else {
            key = storeOpens.open(route) { services.pages.show(.appStore, in: services.windows.active, focus: false) }?.key
        }
        if let key {
            // An open page moves to the route; a page this show made already opened on it, and a
            // tab with no page yet opens on it at its first show.
            webStorePages[key]?.open(route: route)
            waitingStore = nil
            return
        }
        waitingStore = (appID, tab, focus)
        if case let windows = services.windows, windows.restored, windows.controllers.isEmpty { windows.reopenOrCreateWindow() }
    }

    /// The first window opened or a window mounted a pane: a request that
    /// waited runs again (a user run shows the top page as soon as a window
    /// exists; an automation run still waits until a pane can hold its tab).
    func windowDidShowContent() {
        guard let request = waitingStore else { return }
        showStore(appID: request.appID, tab: request.tab, focus: request.focus)
    }

    /// Opens an app's page as a tab of the active window (one per window),
    /// then runs `command` (one of the app's palette ops, by name or its last
    /// segment, for example CodeRouter's connectAccount) in the app when
    /// given. User runs select and
    /// focus the tab; automation opens it without moving focus.
    /// The CodeRouter web page opens without the apps client (it talks to
    /// this Mac's CodeRouter ops, not to the supervisor). Returns the
    /// command's run, whose failure the caller reports.
    @discardableResult
    func openApp(_ appID: String, command: String? = nil, focus: Bool = true, origin: ActionOrigin = .user) throws(AppsServiceError) -> ActionWork? {
        guard let services else { throw .noWindow }
        if appID == CodeRouterPageTab.appID, PageTunables.coderouter.value == .web, command == nil,
           let provider = pageProvider(appID: appID) {
            guard services.pages.show(provider.page, in: services.windows.active, focus: focus) != nil else { throw .noWindow }
            return nil
        }
        if let reason = client.unavailableReason { throw .unavailable(reason) }
        guard let app = client.app(appID), app.installed else { throw .unknownApp }
        guard app.enabled else { throw .disabled }
        guard AppPanePage.opens(app), let provider = pageProvider(appID: appID, codeRouterAsPage: false) else { throw .noPage }
        guard services.pages.show(provider.page, in: services.windows.active, focus: focus) != nil else { throw .noWindow }
        guard let command else { return nil }
        guard let found = app.commands.first(where: { AppCommandPalette.Entry(app: app, command: $0).matches(command) }) else {
            throw .unknownCommand
        }
        return AppCommandPalette.run(AppCommandPalette.Entry(app: app, command: found), services: services, origin: origin)
    }

    /// The page provider of app `appID` (registered on first use): CodeRouter's
    /// web page, else the app's own pane page; nil when the app has no page.
    func pageProvider(appID: String, codeRouterAsPage: Bool = true) -> (any InternalPageProvider)? {
        guard let services else { return nil }
        if codeRouterAsPage, appID == CodeRouterPageTab.appID, PageTunables.coderouter.value == .web {
            let tab = coderouterPage ?? CodeRouterPageTab.make(services)
            if coderouterPage == nil {
                coderouterPage = tab
                services.pages.register(tab)
            }
            return tab
        }
        guard let app = client.app(appID), app.isActive, AppPanePage.opens(app) else { return nil }
        let provider = appPages[appID] ?? AppPanePage(appID: appID, client: client)
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
    var title: String { AppStoreTab.storeTitle }
    var symbol: String { "bag" }
    var icon: IconName? { .store }

    /// The React App Store page; it opens on the route of the show that opened or selected its tab.
    /// Missing page resources (a build without the web bundles) show an empty view, never a second store.
    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let services else { return NSView() }
        let discarded = discardedRoutes.removeValue(forKey: key)
        let route = storeOpens.take(for: key) ?? storeOpens.running ?? discarded ?? Self.storeRoute(appID: nil, tab: nil)
        guard let page = makeStorePage?(route) ?? PageFactory(services: services).appsWebPage(route: route) else { return NSView() }
        webStorePages[key] = page
        return page
    }

    func tabClosed(_ key: String) {
        shownPlaces[key] = nil
        discardedRoutes[key] = nil
        storeOpens.forget(key)
        webStorePages.removeValue(forKey: key)?.close()
    }

    // MARK: Discard (`memoryDiscardInternalPages`)

    /// Ten minutes hidden, as a browser tab (Chrome's proactive_discarding_policy.cc). Installs,
    /// updates and grants run on the daemon's app supervisor, not in the page, so nothing the page
    /// started keeps it.
    func discardPolicy(for key: String) -> ContentDiscardPolicy { .standard }

    /// Its document scroll, and the listing or section the page shows now (its own links move it).
    func saveViewState(for key: String, content: NSView) async -> ContentViewState {
        guard let page = content as? PageWebView else { return ContentViewState() }
        shownPlaces[key] = await page.readShownPlace()
        return ContentViewState(scroll: await page.documentScroll())
    }

    /// The tab stays and its page goes, closed as at ``tabClosed(_:)``; the next page of the tab
    /// opens on the listing or section it showed.
    func viewDiscarded(_ key: String) {
        let read = shownPlaces.removeValue(forKey: key)
        guard let page = webStorePages.removeValue(forKey: key) else { return }
        discardedRoutes[key] = page.discardedPlace(read: read)
        page.close()
    }

    /// The page keeps its own history (its fragment).
    func history(for key: String) -> (any PageHistory)? { nil }

    /// The page's fragment: a listing, else `tab` (Discover by default).
    nonisolated static func storeRoute(appID: String?, tab: AppStoreTab?) -> String {
        if let appID, var query = URLComponents(string: "x:") {
            query.queryItems = [URLQueryItem(name: "app", value: appID)]
            return "#/discover?" + (query.percentEncodedQuery ?? "")
        }
        return "#/" + (tab ?? .discover).rawValue
    }
}

enum AppsServiceError: Error {
    case unknownApp, noPage, noWindow, unknownCommand
    /// Installed but turned off.
    case disabled
    /// The supervisor cannot be reached (an older daemon, not connected yet, or turned off).
    case unavailable(AppsUnavailableReason)
}


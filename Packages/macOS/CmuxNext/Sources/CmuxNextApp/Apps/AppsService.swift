import AppKit
import CmuxNextActions
import CmuxNextApps
import CmuxNextControl
import CmuxNextDaemonService
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
    /// The route of the show running now, for the page it makes (``makeView(for:in:)``).
    private var pendingRoute: String?
    private var machineCatalog: MachineCatalogPublisher?
    init(services: AppServices) {
        self.services = services
        transport = DaemonAppsTransport(daemon: services.daemon, inventoryRoutes: { [weak machines = services.machines] in
            machines?.agentInventoryWatchRoutes() ?? []
        })
        client = AppsClient(transport: transport)
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
        client.start()
        // task-owner: one off-main load of the bundled package directories and the scope table at launch
        Task { [client] in client.useBundledDirectories(await AppPlatformResources.bundledDirectories()) }
    }

    /// Serves app-side operations, admitted machine inventory reads and the
    /// Agent Memory app's search through the supervisor's verified-app provider channel.
    func attach(router: ControlRouter) {
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
            machineCatalog = MachineCatalogPublisher { [weak machines = services.machines] in
                machines?.catalogSource()
            }
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
        guard services.settings?.snapshot.previewFeatures == true else { return }
        pendingRoute = Self.storeRoute(appID: appID, tab: tab)
        let key = focus ? TopPages.show(.page(.appStore), services: services)
            : services.pages.show(.appStore, in: services.windows.active, focus: false)?.key
        if let key {
            // An open page moves to the route; a page this show made already opened on it.
            webStorePages[key]?.open(route: Self.storeRoute(appID: appID, tab: tab))
            pendingRoute = nil
            waitingStore = nil
            return
        }
        pendingRoute = nil
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

    /// Opens an app (``AppOpenTarget``): its scene page as a tab of the active window (one per window)
    /// or its web app as a browser tab in the active workspace,
    /// then runs `command` (one of the app's palette ops, by name or its last
    /// segment, for example CodeRouter's connectAccount) in the app when
    /// given. User runs select and
    /// focus the tab; automation opens it without moving focus.
    /// The CodeRouter web page opens without the apps client (it talks to
    /// this Mac's CodeRouter ops, not to the supervisor). Returns the
    /// command's run, whose failure the caller reports.
    @discardableResult
    func openApp(_ appID: String, command: String? = nil, focus: Bool = true, origin: ActionOrigin = .user) throws(AppsServiceError) -> ActionWork? {
        if appID == CodeRouterPageTab.appID, PageTunables.coderouter.value == .web, command == nil,
           let provider = pageProvider(appID: appID) {
            guard services.pages.show(provider.page, in: services.windows.active, focus: focus) != nil else { throw .noWindow }
            return nil
        }
        if let reason = client.unavailableReason { throw .unavailable(reason) }
        guard let app = client.app(appID), app.installed else { throw .unknownApp }
        guard app.enabled else { throw .disabled }
        switch AppOpenTarget(app) {
        case .scenePane:
            guard AppPanePage.opens(app), let provider = pageProvider(appID: appID, codeRouterAsPage: false) else { throw .noPage }
            guard services.pages.show(provider.page, in: services.windows.active, focus: focus) != nil else { throw .noWindow }
        case .web(let url):
            // A web app is a browser tab in the active workspace, through the one browser-open path
            // (`openBrowser`), so the browser's policy, engine and placement rules apply as for any tab.
            guard services.windows.active != nil else { throw .noWindow }
            let opened = services.registry.perform("openBrowser", invocation: ActionInvocation(
                arguments: ["url": .string(url.absoluteString)], origin: origin, focusRequested: focus))
            guard opened else { throw .noPage }
            return nil
        case .notDeployed:
            throw .notDeployed
        case .none:
            throw .noPage
        }
        guard let command else { return nil }
        guard let found = app.commands.first(where: { AppCommandPalette.Entry(app: app, command: $0).matches(command) }) else {
            throw .unknownCommand
        }
        return AppCommandPalette.run(AppCommandPalette.Entry(app: app, command: found), services: services, origin: origin)
    }

    /// The page provider of app `appID` (registered on first use): CodeRouter's
    /// web page, else the app's own pane page; nil when the app has no page.
    func pageProvider(appID: String, codeRouterAsPage: Bool = true) -> (any InternalPageProvider)? {
        if codeRouterAsPage, appID == CodeRouterPageTab.appID, PageTunables.coderouter.value == .web {
            let tab = coderouterPage ?? CodeRouterPageTab.make(services)
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
    var title: String { AppStoreTab.storeTitle }
    var symbol: String { "bag" }
    var icon: IconName? { .store }

    /// The React App Store page; it opens on the route of the show that made it. Missing page
    /// resources (a build without the web bundles) show an empty view, never a second store.
    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let page = PageFactory(services: services).appsWebPage(route: pendingRoute ?? Self.storeRoute(appID: nil, tab: nil)) else {
            return NSView()
        }
        webStorePages[key] = page
        return page
    }

    func tabClosed(_ key: String) {
        webStorePages.removeValue(forKey: key)?.close()
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
    /// A remote pane whose instance is not running yet (install it with a deploy target).
    case notDeployed
    /// Installed but turned off.
    case disabled
    /// The supervisor cannot be reached (an older daemon, not connected yet, or turned off).
    case unavailable(AppsUnavailableReason)
}


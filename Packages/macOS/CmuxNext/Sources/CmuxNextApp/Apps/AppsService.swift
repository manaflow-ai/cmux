import AppKit
import CmuxNextApps
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextIcons
import CmuxNextPages
import Foundation
import Synchronization

/// App platform in the App (plans/cmux-next/app-platform.md), DEV
/// prototype: the prototype registry, the JavaScriptCore app host with its
/// operation sink, and catalog event fan-out from the control snapshot.
/// The router-backed sink attaches when the control socket starts; calls
/// before that answer `unavailable`.
@MainActor
final class AppsService {
    unowned let services: AppServices
    let registry: AppRegistry
    let host: AppHost
    let storage: AppStorageStore
    private let sink = DeferredAppSink()
    /// The control router once the socket starts (the CodeRouter page's ops run on it).
    private(set) var controlRouter: ControlRouter?
    /// The React CodeRouter page tab (Debug Settings `coderouter.surface = web`), registered on first open.
    private var coderouterPage: CodeRouterPageTab?
    private var fingerprints: [String: Int] = [:]
    /// An App Store request made while no main window could hold it (S22:
    /// the App Store is never a window of its own); the first window that
    /// mounts a pane shows it (`windowDidShowContent`).
    private var waitingStore: (appID: String?, installed: Bool, focus: Bool)?
    var isStoreWaiting: Bool { waitingStore != nil }
    /// App pages (`app:<id>`), one provider per app, registered on first open.
    private var appPages: [String: AppPanePage] = [:]
    /// The React App Store page per tab (Debug Settings `apps.store.surface = web`), else empty.
    private var webStorePages: [String: PageWebView] = [:]
    /// The App Store tabs (internal page), one store model per tab.
    private(set) lazy var storePages = AppStorePages { [unowned self] in makeStoreModel() }
    /// Runs previews of apps that are not installed (sample data, no grant).
    private lazy var previewHost = AppHost(sink: AppPreviewSink())

    init(services: AppServices) {
        self.services = services
        let directory = AppRegistryFile.appsDirectory(tag: services.environment.tag)
        registry = AppRegistry(directory: directory)
        storage = AppStorageStore(directory: directory.appending(path: "storage", directoryHint: .isDirectory))
        host = AppHost(sink: sink)
        host.grants = { [weak self] manifest in
            self?.registry.app(manifest.id)?.grants ?? AppGrants.Snapshot(scopes: [], sandboxed: true)
        }
        registry.onChange = { [weak self] app in self?.host.refreshGrants(app.manifest) }
    }

    /// Turning apps off stops every running app and refuses new starts
    /// (DisabledFeatures); open app pages show "Turned off by your organization".
    func applyPolicy(disabled: Bool) {
        host.disabledReason = disabled ? RefusalStrings.turnedOffByOrganization : nil
    }

    func start() {
        // task-owner: one-shot registry scan at launch; an open store lists the result.
        Task { [weak self] in
            await self?.registry.load()
            self?.storePages.refreshAll()
        }
    }

    /// Wires the sink to the control router (reads, action.run) and the daemon.
    func attach(router: ControlRouter) {
        controlRouter = router
        let daemon = services.daemon
        let ledger: @Sendable () async throws -> [ListNotificationsRequest.Entry] = {
            guard let connection = await MainActor.run(body: { daemon.connection }) else {
                throw AppOperationError(code: "unavailable", message: "the daemon is not connected", retryable: true)
            }
            return try await connection.notificationLedger(limit: 200)
        }
        sink.attach(AppOperationRouter(router: router, storage: storage, ledger: ledger))
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
    /// then runs `command` (a `contributes.commands` id) in the app when
    /// given, for example CodeRouter's connectAccount. User runs select and
    /// focus the tab; automation opens it without moving focus.
    func openApp(_ appID: String, command: String? = nil, focus: Bool = true) throws(AppsServiceError) {
        guard let app = registry.app(appID), app.isActive else { throw .unknownApp }
        let codeRouter = appID == CodeRouterPageTab.appID && PageTunables.coderouter.value == .web
        if codeRouter, command == nil, let provider = pageProvider(appID: appID) {
            guard services.pages.show(provider.page, in: services.windows.active, focus: focus) != nil else { throw .noWindow }
            return
        }
        guard AppPanePage.opens(app), let provider = pageProvider(appID: appID, codeRouterAsPage: false) else { throw .noPage }
        guard services.pages.show(provider.page, in: services.windows.active, focus: focus) != nil else { throw .noWindow }
        if let command {
            guard let entry = AppCommandPalette.entries(registry, includingNonPalette: true).first(where: { $0.app.id == appID && $0.command.id == command }) else {
                throw .unknownCommand
            }
            AppCommandPalette.run(entry, services: services)
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
        guard let app = registry.app(appID), app.isActive, AppPanePage.opens(app) else { return nil }
        let provider = appPages[appID] ?? AppPanePage(appID: appID, apps: self)
        if appPages[appID] == nil {
            appPages[appID] = provider
            services.pages.register(provider)
        }
        return provider
    }

    private func makeStoreModel() -> AppStoreModel {
        let model = AppStoreModel(catalog: RegistryAppStoreCatalog(registry: registry), registry: registry, host: host, previewHost: previewHost)
        model.onRemoved = { [storage] id in await storage.clear(app: id) }
        model.onNavigate = { [weak self] in self?.services.locationTrail.pageHistoryDidChange() }
        return model
    }

    /// Posts `<family>.changed` for streams an app listens to, when the
    /// published mirror changed for that family.
    func topologyPublished(_ topology: ControlTopology) {
        let active = host.events.activeStreams
        guard !active.isEmpty else { return }
        for (stream, value) in AppTopologyReads.fingerprints(topology) where active.contains(stream) {
            if fingerprints[stream] != value {
                let first = fingerprints[stream] == nil
                fingerprints[stream] = value
                if !first { host.events.post(stream) }
            }
        }
    }
}

/// The sink the host holds from launch; the real one attaches when the
/// control router exists.
nonisolated final class DeferredAppSink: AppOperationSink, Sendable {
    private let inner = Mutex<(any AppOperationSink)?>(nil)

    func attach(_ sink: any AppOperationSink) { inner.withLock { $0 = sink } }

    func perform(_ request: AppOperationRequest) async -> Result<AppOperationResult, AppOperationError> {
        guard let sink = inner.withLock({ $0 }) else {
            return .failure(AppOperationError(code: "unavailable", message: "cmux is still starting", retryable: true))
        }
        return await sink.perform(request)
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


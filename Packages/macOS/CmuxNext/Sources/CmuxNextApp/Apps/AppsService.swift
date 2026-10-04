import AppKit
import CmuxNextApps
import CmuxNextControl
import CmuxNextDaemon
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
    private var fingerprints: [String: Int] = [:]
    private var store: AppStoreWindowController?
    private var storeModel: AppStoreModel?
    /// App pages (`app:<id>`), one provider per app, registered on first open.
    private var appPages: [String: AppPanePage] = [:]
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
            self?.storeModel?.refresh()
            self?.storePages.refreshAll()
        }
    }

    /// Wires the sink to the control router (reads, action.run) and the daemon.
    func attach(router: ControlRouter) {
        let daemon = services.daemon
        let ledger: @Sendable () async throws -> [ListNotificationsRequest.Entry] = {
            guard let connection = await MainActor.run(body: { daemon.connection }) else {
                throw AppOperationError(code: "unavailable", message: "the daemon is not connected", retryable: true)
            }
            return try await connection.notificationLedger(limit: 200)
        }
        sink.attach(AppOperationRouter(router: router, storage: storage, ledger: ledger))
    }

    /// Opens the App Store (palette "App Store", `appStore.show`) as a tab
    /// of the active window (internal page `app-store`, one per window);
    /// `appID` opens that listing, `installed` the Installed tab. A user run
    /// selects and focuses the tab; automation opens it without moving
    /// focus. Falls back to the App Store window when no main window can
    /// hold the tab.
    func showStore(appID: String? = nil, installed: Bool = false, focus: Bool = true) {
        if let view = services.pages.show(.appStore, in: services.windows.active, focus: focus) {
            storePages.present(view.key, appID: appID, installed: installed)
            return
        }
        if store == nil {
            // No disk I/O here: the catalog reads the registry's launch scan.
            let model = makeStoreModel()
            storeModel = model
            let controller = AppStoreWindowController(model: model)
            controller.onClose = { [weak self] in
                self?.store = nil
                self?.storeModel = nil
            }
            store = controller
        }
        store?.setThemeScope(services.windows.active?.themeScope ?? .app)
        store?.present(appID: appID, installed: installed)
    }

    /// Opens an app's page as a tab of the active window (one per window),
    /// then runs `command` (a `contributes.commands` id) in the app when
    /// given, for example CodeRouter's connectAccount. User runs select and
    /// focus the tab; automation opens it without moving focus.
    func openApp(_ appID: String, command: String? = nil, focus: Bool = true) throws(AppsServiceError) {
        guard let app = registry.app(appID), app.isActive else { throw .unknownApp }
        guard AppPanePage.opens(app) else { throw .noPage }
        let provider = appPages[appID] ?? AppPanePage(appID: appID, apps: self)
        if appPages[appID] == nil {
            appPages[appID] = provider
            services.pages.register(provider)
        }
        guard services.pages.show(provider.page, in: services.windows.active, focus: focus) != nil else { throw .noWindow }
        if let command {
            guard let entry = AppCommandPalette.entries(registry, includingNonPalette: true).first(where: { $0.app.id == appID && $0.command.id == command }) else {
                throw .unknownCommand
            }
            AppCommandPalette.run(entry, services: services)
        }
    }

    private func makeStoreModel() -> AppStoreModel {
        let model = AppStoreModel(catalog: RegistryAppStoreCatalog(registry: registry), registry: registry, host: host, previewHost: previewHost)
        model.onRemoved = { [storage] id in await storage.clear(app: id) }
        return model
    }

    var storeWindow: NSWindow? { store?.window }

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

    func makeView(for key: String, in window: WindowController?) -> NSView { storePages.makeView(for: key) }

    func tabClosed(_ key: String) { storePages.tabClosed(key) }
}

enum AppsServiceError: Error {
    case unknownApp, noPage, noWindow, unknownCommand
}


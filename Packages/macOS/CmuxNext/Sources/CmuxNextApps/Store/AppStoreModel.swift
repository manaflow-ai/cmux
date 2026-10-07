public import Foundation
public import Observation

/// The App Store window's state (app-platform.md step 6): Discover
/// (search, category chips, listings, detail with a live preview) and
/// Installed (enable, reload, remove, logs). Install and remove are only
/// reachable from this window's buttons, which are user gestures.
@MainActor
@Observable
public final class AppStoreModel {
    public enum Tab: String, Sendable, Hashable, CaseIterable {
        case discover
        case installed
    }

    public var tab: Tab = .discover
    public var query = "" { didSet { if query != oldValue { refresh() } } }
    public var category: String? { didSet { if category != oldValue { refresh() } } }
    public private(set) var listings: [AppStoreListing] = []
    public private(set) var allCategories: [String] = []
    public var selection: String?
    public private(set) var loadError: String?
    /// Installed app whose log is expanded.
    public var logsShown: String?
    /// Installed app whose permissions are expanded.
    public var grantsShown: String?
    /// Demo and screenshot overrides of the Debug Settings prototypes.
    public var layoutOverride: AppStoreLayout?
    public var lookOverride: AppSectionLook?

    public let registry: AppRegistry
    /// Runs installed, enabled apps (real data, the app's grant).
    public let host: AppHost
    /// Runs previews of apps that are not installed (sample data, no grant).
    public let previewHost: AppHost
    @ObservationIgnored let catalog: any AppStoreCatalog
    /// Called after a remove (the App deletes the app's storage).
    @ObservationIgnored public var onRemoved: ((String) async -> Void)?
    @ObservationIgnored private var search: Task<Void, Never>?

    public init(catalog: any AppStoreCatalog, registry: AppRegistry, host: AppHost, previewHost: AppHost) {
        self.catalog = catalog
        self.registry = registry
        self.host = host
        self.previewHost = previewHost
    }

    public var layout: AppStoreLayout { layoutOverride ?? AppsTunables.storeLayout.value }
    public var look: AppSectionLook { lookOverride ?? AppsTunables.sectionLook.value }
    public var installedApps: [InstalledApp] { registry.apps.filter(\.isInstalled) }
    public var selectedListing: AppStoreListing? { listings.first { $0.id == selection } }

    public func state(of id: String) -> InstalledApp? { registry.app(id) }

    /// Re-runs the search with the current query and category.
    public func refresh() {
        search?.cancel()
        let (query, category, catalog) = (query, category, catalog)
        search = Task { [weak self] in
            do {
                let found = try await catalog.search(query: query, category: category)
                let everything = category == nil && query.isEmpty ? found : try await catalog.search(query: "", category: nil)
                guard !Task.isCancelled, let self else { return }
                listings = found
                allCategories = Self.categories(of: everything)
                loadError = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.loadError = String(describing: error)
            }
        }
    }

    /// Opens a listing (`appStore.show` with `app`): clears filters so it shows.
    /// The App Store's title (window and tab).
    public static var title: String { AppsStrings.windowTitle }

    /// Shows `appID`'s listing, else the Installed tab when `installed`.
    public func present(appID: String?, installed: Bool) {
        if let appID { open(appID: appID) } else if installed { tab = .installed }
    }

    public func open(appID: String) {
        tab = .discover
        if !listings.contains(where: { $0.id == appID }) {
            query = ""
            category = nil
        }
        selection = appID
    }

    public func install(_ id: String) async throws {
        try await registry.install(id)
    }

    public func remove(_ id: String) async throws {
        await host.stop(id, reason: "removed")
        try await registry.remove(id)
        await onRemoved?(id)
    }

    public func setEnabled(_ id: String, _ enabled: Bool) async throws {
        if !enabled { await host.stop(id, reason: "disabled") }
        try await registry.setEnabled(id, enabled)
    }

    /// Revoke or grant one scope; the app's next call sees it.
    public func setGranted(_ id: String, scope: String, _ granted: Bool) async throws {
        try await registry.setGranted(id, scope: scope, granted)
    }

    /// The "Run sandboxed" switch.
    public func setSandboxed(_ id: String, _ sandboxed: Bool) async throws {
        try await registry.setSandboxed(id, sandboxed)
    }

    public func reload(_ id: String) async {
        guard let app = registry.app(id) else { return }
        await host.reload(app.manifest, directory: app.bundle.directory)
    }

    static func categories(of listings: [AppStoreListing]) -> [String] {
        var seen = Set<String>()
        return listings.flatMap(\.categories).filter { seen.insert($0).inserted }.sorted()
    }
}

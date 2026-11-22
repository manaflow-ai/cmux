public import Foundation
public import Observation
import CmuxNextWakeups

/// The App Store window's state (app-platform.md step 6): Discover
/// (search, category chips, listings, detail with a live preview) and
/// Installed (enable, reload, remove, logs). Install and remove are only
/// reachable from this window's buttons, which are user gestures.
///
/// Page history: every change of tab or opened listing is a navigation
/// (``show(_:selection:)``), with Back and Forward lists like a browser
/// tab's. The titlebar arrows, Cmd-[ / Cmd-], the mouse buttons, a swipe
/// and the detail page's crumb all walk them (``goBack()``).
@MainActor
@Observable
public final class AppStoreModel {
    public enum Tab: String, Sendable, Hashable, CaseIterable {
        case discover
        case installed
    }

    /// One entry of the page history: what the page showed, with the
    /// search that led there.
    public struct Location: Hashable, Sendable {
        public var tab: Tab
        public var selection: String?
        public var query: String
        public var category: String?
    }

    public private(set) var tab: Tab = .discover
    public var query = "" { didSet { if query != oldValue { refresh() } } }
    public var category: String? { didSet { if category != oldValue { refresh() } } }
    public private(set) var listings: [AppStoreListing] = []
    public private(set) var allCategories: [String] = []
    public private(set) var selection: String?
    /// Older locations, newest last.
    public private(set) var backList: [Location] = []
    /// Locations left by Back, the next one last.
    public private(set) var forwardList: [Location] = []
    /// An app whose Remove waits for its undo window (``requestRemove(_:)``).
    public private(set) var pendingRemoval: String?
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
    /// Called after every page navigation (the titlebar arrows re-read
    /// ``canGoBack`` and ``canGoForward``).
    @ObservationIgnored public var onNavigate: (() -> Void)?
    @ObservationIgnored private var search: Task<Void, Never>?
    @ObservationIgnored private let removalTimer = DemandTimer(owner: "AppStoreModel.removal")
    @ObservationIgnored private var removalWasEnabled = true
    /// How long a Remove can be undone before it is committed.
    @ObservationIgnored var removalUndoInterval: Duration = .seconds(6)

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

    /// The App Store's title (window and tab).
    public static var title: String { AppsStrings.windowTitle }

    /// Shows `appID`'s listing, else the Installed tab when `installed`.
    public func present(appID: String?, installed: Bool) {
        if let appID { open(appID: appID) } else if installed { show(.installed) }
    }

    /// Opens a listing (`appStore.show` with `app`): clears filters so it shows.
    public func open(appID: String) {
        guard tab != .discover || selection != appID else { return }
        record()
        tab = .discover
        if !listings.contains(where: { $0.id == appID }) {
            query = ""
            category = nil
        }
        selection = appID
        onNavigate?()
    }

    // MARK: Page history

    /// The page shows `tab` with `selection` open (nil: the listings): a
    /// new entry in the page history unless it already shows exactly that.
    public func show(_ tab: Tab, selection: String? = nil) {
        guard tab != self.tab || selection != self.selection else { return }
        record()
        self.tab = tab
        self.selection = selection
        onNavigate?()
    }

    public var location: Location { Location(tab: tab, selection: selection, query: query, category: category) }
    public var canGoBack: Bool { !backList.isEmpty }
    public var canGoForward: Bool { !forwardList.isEmpty }

    /// Back within the page. False when the page is at its first location.
    @discardableResult
    public func goBack() -> Bool {
        guard let previous = backList.popLast() else { return false }
        forwardList.append(location)
        restore(previous)
        return true
    }

    /// Forward within the page. False when nothing was left by Back.
    @discardableResult
    public func goForward() -> Bool {
        guard let next = forwardList.popLast() else { return false }
        backList.append(location)
        restore(next)
        return true
    }

    /// Pushes the current location before a navigation; a new navigation
    /// drops what Back left.
    private func record() {
        backList.append(location)
        if backList.count > Self.historyCapacity { backList.removeFirst(backList.count - Self.historyCapacity) }
        forwardList.removeAll()
    }

    private func restore(_ location: Location) {
        tab = location.tab
        selection = location.selection
        query = location.query
        category = location.category
        onNavigate?()
    }

    static let historyCapacity = 100

    public func install(_ id: String) async throws {
        try await registry.install(id)
    }

    public func remove(_ id: String) async throws {
        await host.stop(id, reason: "removed")
        try await registry.remove(id)
        await onRemoved?(id)
    }

    /// Remove without a confirmation: the app stops at once and is removed
    /// (its storage deleted) after ``removalUndoInterval`` unless
    /// ``undoRemove()`` runs first. A second request commits the first.
    public func requestRemove(_ id: String) async {
        await commitPendingRemoval()
        removalWasEnabled = state(of: id)?.isEnabled ?? true
        pendingRemoval = id
        try? await setEnabled(id, false)
        removalTimer.schedule(after: removalUndoInterval) { @MainActor [weak self] in
            await self?.commitRemoval()
        }
    }

    /// Takes back a pending Remove: the app runs again as it did.
    public func undoRemove() async {
        guard let id = pendingRemoval else { return }
        removalTimer.cancel()
        pendingRemoval = nil
        if removalWasEnabled { try? await setEnabled(id, true) }
    }

    /// Removes the pending app now, before its undo window ends.
    public func commitPendingRemoval() async {
        removalTimer.cancel()
        await commitRemoval()
    }

    /// The undo window ended (the timer's fire, which must not cancel itself).
    private func commitRemoval() async {
        guard let id = pendingRemoval else { return }
        pendingRemoval = nil
        try? await remove(id)
    }

    public func setEnabled(_ id: String, _ enabled: Bool) async throws {
        if !enabled { await host.stop(id, reason: "disabled") }
        try await registry.setEnabled(id, enabled)
        // Back on (a toggle or an undone Remove): the Installed row no longer reads "disabled".
        if enabled { host.forgetStopReason(id) }
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

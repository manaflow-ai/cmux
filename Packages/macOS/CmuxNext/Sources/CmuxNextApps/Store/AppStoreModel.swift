public import Foundation
public import Observation
import CmuxNextWakeups

/// The App Store page's state (app-platform.md step 6): Discover (search,
/// category chips, listings, detail with a live preview) and Installed
/// (grants, Run sandboxed, Hide/Show, enable, remove, logs). Every listing
/// and install state comes from the app supervisor through `AppsClient`;
/// install, remove and grant changes are reachable only from this page's
/// controls, which are user gestures (origin `user`). While the supervisor
/// is unreachable every control is disabled and the page says why.
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
    public var query = ""
    public var category: String?
    public private(set) var selection: String?
    /// Older locations, newest last.
    public private(set) var backList: [Location] = []
    /// Locations left by Back, the next one last.
    public private(set) var forwardList: [Location] = []
    /// An app whose Remove waits for its undo window (``requestRemove(_:)``).
    public private(set) var pendingRemoval: String?
    /// Installed app whose log is expanded.
    public var logsShown: String? { didSet { if let logsShown, logsShown != oldValue { client.followLogs(logsShown) } } }
    /// Installed app whose permissions are expanded.
    public var grantsShown: String?
    /// Demo and screenshot overrides of the Debug Settings prototypes.
    public var layoutOverride: AppStoreLayout?
    public var lookOverride: AppSectionLook?

    public let client: AppsClient
    /// Called after every page navigation (the titlebar arrows re-read
    /// ``canGoBack`` and ``canGoForward``).
    @ObservationIgnored public var onNavigate: (() -> Void)?
    @ObservationIgnored private let removalTimer = DemandTimer(owner: "AppStoreModel.removal")
    @ObservationIgnored private var removalWasEnabled = true
    /// How long a Remove can be undone before it is committed.
    @ObservationIgnored var removalUndoInterval: Duration = .seconds(6)

    public init(client: AppsClient) {
        self.client = client
    }

    public var layout: AppStoreLayout { layoutOverride ?? AppsTunables.storeLayout.value }
    public var look: AppSectionLook { lookOverride ?? AppsTunables.sectionLook.value }
    /// Whether changes can be sent (the supervisor answers).
    public var canChange: Bool { client.isAvailable }

    /// Every app the supervisor knows, as listings, filtered by the search
    /// and category. `local/` development apps, apps whose package the
    /// daemon does not have, and the App Store itself are never listed.
    public var listings: [AppStoreListing] {
        allListings.filter { listing in (category.map { listing.categories.contains($0) } ?? true) && listing.matches(query) }
    }

    public var allCategories: [String] { Set(allListings.flatMap(\.categories)).sorted() }

    private var allListings: [AppStoreListing] {
        client.apps.filter { !$0.manifest.isLocal && $0.available && $0.id != AppStoreListing.storeID }.map(AppStoreListing.init(record:))
    }

    public var installedApps: [AppRecord] { client.apps.filter(\.installed) }
    public var selectedListing: AppStoreListing? { allListings.first { $0.id == selection } }
    public func state(of id: String) -> AppRecord? { client.app(id) }

    /// Lists again (the page opened).
    public func refresh() { client.refresh() }

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

    // MARK: User changes (every one a gesture on this page)

    public func install(_ id: String) async throws(AppsClientError) { try await client.install(id) }

    /// Removes the app now (the supervisor stops it and deletes its storage).
    public func remove(_ id: String) async throws(AppsClientError) { try await client.remove(id) }

    /// Remove without a confirmation: the app is disabled at once and
    /// removed after ``removalUndoInterval`` unless ``undoRemove()`` runs
    /// first. A second request commits the first.
    public func requestRemove(_ id: String) async {
        await commitPendingRemoval()
        removalWasEnabled = state(of: id)?.enabled ?? true
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

    public func setEnabled(_ id: String, _ enabled: Bool) async throws(AppsClientError) {
        try await client.set(id, .enable(enabled), origin: .user)
    }

    public func setHidden(_ id: String, _ hidden: Bool) async throws(AppsClientError) {
        try await client.set(id, .hide(hidden), origin: .user)
    }

    /// Grant or revoke one scope; the supervisor refuses the app's next call.
    public func setGranted(_ id: String, scope: String, _ granted: Bool) async throws(AppsClientError) {
        try await client.set(id, .grant(scope, granted), origin: .user)
    }

    /// The "Run sandboxed" switch.
    public func setSandboxed(_ id: String, _ sandboxed: Bool) async throws(AppsClientError) {
        try await client.set(id, .sandbox(sandboxed), origin: .user)
    }
}

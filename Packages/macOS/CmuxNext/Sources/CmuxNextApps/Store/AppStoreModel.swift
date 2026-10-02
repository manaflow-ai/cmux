public import Foundation
public import Observation

/// The App Store window's state: Discover (search, category chips,
/// listings, detail with a live preview) and Installed (grants, Run
/// sandboxed, Hide/Show, enable, logs). Every listing and install state
/// comes from the app supervisor through `AppsClient`; install, remove and
/// grant changes are only reachable from this window's controls, which are
/// user gestures (origin `user`). While the supervisor is unreachable every
/// control is disabled and the window says why.
@MainActor
@Observable
public final class AppStoreModel {
    public enum Tab: String, Sendable, Hashable, CaseIterable {
        case discover
        case installed
    }

    public var tab: Tab = .discover
    public var query = ""
    public var category: String?
    public var selection: String?
    /// Installed app whose log is expanded.
    public var logsShown: String? { didSet { if let logsShown, logsShown != oldValue { followLogs(logsShown) } } }
    /// Installed app whose permissions are expanded.
    public var grantsShown: String?
    /// Demo and screenshot overrides of the Debug Settings prototypes.
    public var layoutOverride: AppStoreLayout?
    public var lookOverride: AppSectionLook?

    public let client: AppsClient

    public init(client: AppsClient) {
        self.client = client
    }

    public var layout: AppStoreLayout { layoutOverride ?? AppsTunables.storeLayout.value }
    public var look: AppSectionLook { lookOverride ?? AppsTunables.sectionLook.value }
    /// Whether changes can be sent (the supervisor answers).
    public var canChange: Bool { client.isAvailable }

    /// Every app the supervisor knows, as listings, filtered by the search
    /// and category. `local/` development apps are never listed.
    public var listings: [AppStoreListing] {
        client.apps.filter { !$0.manifest.isLocal }.map(AppStoreListing.init(record:))
            .filter { (category == nil || $0.categories.contains(category!)) && $0.matches(query) }
    }

    public var allCategories: [String] {
        Set(client.apps.flatMap(\.manifest.categories)).sorted()
    }

    public var installedApps: [AppRecord] { client.apps.filter(\.installed) }
    public var selectedListing: AppStoreListing? { listings.first { $0.id == selection } }
    public func state(of id: String) -> AppRecord? { client.app(id) }

    /// Opens a listing (`appStore.show` with `app`): clears filters so it shows.
    public func open(appID: String) {
        tab = .discover
        if !listings.contains(where: { $0.id == appID }) {
            query = ""
            category = nil
        }
        selection = appID
    }

    /// Lists again (the window opened).
    public func refresh() { client.refresh() }

    // MARK: User changes (every one a gesture in this window)

    public func install(_ id: String) async throws(AppsClientError) { try await client.install(id) }
    public func remove(_ id: String) async throws(AppsClientError) { try await client.remove(id) }

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

    private func followLogs(_ id: String) {
        // task-owner: one log load when the log is expanded
        Task { [client] in await client.followLogs(id) }
    }
}

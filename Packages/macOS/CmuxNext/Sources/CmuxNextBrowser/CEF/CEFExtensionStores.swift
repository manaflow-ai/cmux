import Foundation

/// The extension mirrors, one per profile, created on first use. Owns the
/// mirrors and decides which ones a Chromium extension change refreshes.
@MainActor
final class CEFExtensionStores {
    unowned let runtime: CEFRuntime
    private var stores: [BrowserProfileID: BrowserExtensionStore] = [:]

    init(runtime: CEFRuntime) {
        self.runtime = runtime
    }

    /// The extension mirror of `profile` (created on first use).
    func store(for profile: BrowserProfileID) -> BrowserExtensionStore {
        if let store = stores[profile] { return store }
        let store = BrowserExtensionStore(profile: profile, backend: CEFExtensionBackend(runtime: runtime, profile: profile))
        stores[profile] = store
        return store
    }

    func hasStore(for profile: BrowserProfileID) -> Bool { stores[profile] != nil }

    /// Extensions or their actions changed: refresh the profile mirrors of
    /// the window's tabs (a pin changes both lists).
    func refresh(window: Int32, browser: Int32) {
        runtime.omniboxKeywords.invalidate()
        var profiles: Set<BrowserProfileID> = []
        if let tab = runtime.tabsByBrowser[browser] { profiles.insert(tab.profileID) }
        for host in runtime.hosts.values where host.owns(window: window) { profiles.insert(host.key.profile) }
        if profiles.isEmpty { profiles = Set(stores.keys) }
        for profile in profiles { stores[profile]?.refresh() }
    }
}

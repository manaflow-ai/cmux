import CmuxNextBrowser
import CmuxNextRemoteLocalhost
import Foundation

/// Browser tabs whose Chromium store goes through a Cloud machine's proxy
/// (`browser.tab.open` from the Cloud page). Their URL is that machine's
/// localhost, so the store must follow the tab for its whole life: every
/// Chromium page of the tab (wake from hibernation, store reroute, history
/// page exit) gets it back, and no WebKit page of the tab loads its URL.
///
/// The live stores are in memory (their proxy ports end with the app). The
/// tab ids are also kept in `UserDefaults`, so after a relaunch a proxied tab
/// whose proxy is gone stays blank instead of loading this Mac's localhost.
@MainActor
final class ProxiedBrowserTabs {
    enum Plan: Equatable {
        /// Not a proxied tab: the normal route (remote localhost) decides.
        case notProxied
        /// The configuration for the page.
        case configured(BrowserTabConfiguration)
        /// A proxied tab without a live proxy: the page must stay blank.
        case blocked
    }

    static let defaultsKey = "cmux.next.browser.proxiedTabs"
    /// Kept ids, oldest dropped first.
    static let keptLimit = 1024

    private let defaults: UserDefaults
    private var live: [String: BrowserMachineStore] = [:]
    /// Machine keys of Cloud proxy stores this launch.
    private var cloudKeys: Set<String> = []
    private var kept: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        kept = defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    /// A Cloud proxy store whose page a daemon tab is about to adopt.
    func expect(_ store: BrowserMachineStore) {
        cloudKeys.insert(store.machineKey)
    }

    func record(_ key: String, store: BrowserMachineStore) {
        cloudKeys.insert(store.machineKey)
        live[key] = store
        guard !kept.contains(key) else { return }
        kept.append(key)
        if kept.count > Self.keptLimit { kept.removeFirst(kept.count - Self.keptLimit) }
        defaults.set(kept, forKey: Self.defaultsKey)
    }

    /// A page installed for tab `key` with `store`: recorded when the store
    /// is a Cloud proxy store (a popup or duplicate of a proxied page).
    func adopt(store: BrowserMachineStore?, key: String) {
        guard let store, live[key] == nil, cloudKeys.contains(store.machineKey) else { return }
        record(key, store: store)
    }

    func isProxied(_ key: String) -> Bool {
        live[key] != nil || kept.contains(key)
    }

    /// `address`, the favicon of tab `key`, when the app may fetch it itself:
    /// nil for a loopback icon of a remote store (a remote-localhost page or a
    /// proxied tab), which would load from this Mac (URL.isAppFetchableFavicon).
    func appFetchableFavicon(_ address: String?, key: String, page: (any BrowserTab)?) -> String? {
        let remote = (page as? CEFTab)?.machineStore != nil || isProxied(key)
        guard let address, let url = URL(string: address) else { return address }
        return url.isAppFetchableFavicon(remoteStore: remote) ? address : nil
    }

    /// `plan` as the cache's configuration hook: nil (a blank page) for a
    /// blocked tab, `otherwise` for a tab that is not proxied.
    func configuration(for key: String, url: URL?, base: BrowserTabConfiguration,
                       otherwise: () async -> BrowserTabConfiguration?) async -> BrowserTabConfiguration? {
        switch plan(for: key, url: url, base: base) {
        case .configured(let configuration): configuration
        case .blocked: nil
        case .notProxied: await otherwise()
        }
    }

    /// The Chromium configuration of tab `key` showing `url`: a loopback
    /// URL (or none) keeps the proxied store and may not leave loopback; any
    /// other URL uses the profile's store and may not reach loopback.
    func plan(for key: String, url: URL?, base: BrowserTabConfiguration) -> Plan {
        guard let store = live[key] else { return kept.contains(key) ? .blocked : .notProxied }
        var configuration = base
        if url.map({ LoopbackHost(url: $0)?.isLoopback == true }) ?? true {
            configuration.machineStore = store
            configuration.navigationGuard = .loopbackOnly
        } else {
            configuration.machineStore = nil
            configuration.navigationGuard = .noLoopback
        }
        return .configured(configuration)
    }
}

package import CmuxNextBrowser
package import CmuxNextRemoteLocalhost
package import Foundation

/// Browser tabs whose Chromium store goes through a Cloud machine's proxy
/// (`browser.tab.open` from the Cloud page). Their URL is that machine's
/// localhost, so the store must follow the tab for its whole life: every
/// Chromium page of the tab (wake from hibernation, store reroute, history
/// page exit) gets it back, and no WebKit page of the tab loads its URL.
///
/// The live stores are in memory (their proxy ports end with the app). The
/// tab ids are also kept in `UserDefaults`, so after a relaunch a proxied tab
/// never loads this Mac's localhost. With its machine kept too (#25595), the
/// tab gets a store whose route is fetched again (``restore``); without one
/// (kept by an older build) its loopback page stays blank.
@MainActor
package final class ProxiedBrowserTabs {
    package enum Plan: Equatable {
        /// Not a proxied tab: the normal route (remote localhost) decides.
        case notProxied
        /// The configuration for the page.
        case configured(BrowserTabConfiguration)
        /// A proxied tab without a live proxy: the page must stay blank.
        case blocked
    }

    /// The Cloud machine a proxied tab's store goes to.
    package nonisolated struct Machine: Equatable, Sendable {
        package var id: String
        package var name: String

        package init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    package static let defaultsKey = "cmux.next.browser.proxiedTabs"
    /// Kept tab id to `[machine id, machine name]`.
    package static let machinesKey = "cmux.next.browser.proxiedTabMachines"
    /// Kept ids, oldest dropped first.
    package static let keptLimit = 1024

    private let defaults: UserDefaults
    private var live: [String: BrowserMachineStore] = [:]
    /// Machine keys of Cloud proxy stores this launch.
    private var cloudKeys: Set<String> = []
    private var kept: [String]
    /// The machine of each Cloud proxy store this launch, by machine key.
    private var storeMachines: [String: Machine] = [:]
    /// The machine of each kept tab.
    private var keptMachines: [String: Machine]
    /// A restored tab's store (``RemoteLocalhostService/restoredCloudBrowserStore``): set by the
    /// app; nil, or a nil answer, keeps the restored tab blank.
    package var restore: (@MainActor (Machine) async -> BrowserMachineStore?)?

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        kept = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        let stored = defaults.dictionary(forKey: Self.machinesKey) as? [String: [String]] ?? [:]
        keptMachines = stored.compactMapValues { $0.count == 2 ? Machine(id: $0[0], name: $0[1]) : nil }
    }

    /// A Cloud proxy store of `machine` whose page a daemon tab is about to adopt.
    package func expect(_ store: BrowserMachineStore, machine: Machine) {
        cloudKeys.insert(store.machineKey)
        storeMachines[store.machineKey] = machine
    }

    package func record(_ key: String, store: BrowserMachineStore) {
        cloudKeys.insert(store.machineKey)
        live[key] = store
        let machine = storeMachines[store.machineKey]
        guard !kept.contains(key) || (machine != nil && keptMachines[key] != machine) else { return }
        if !kept.contains(key) { kept.append(key) }
        keptMachines[key] = machine
        if kept.count > Self.keptLimit {
            for dropped in kept.prefix(kept.count - Self.keptLimit) { keptMachines[dropped] = nil }
            kept.removeFirst(kept.count - Self.keptLimit)
        }
        defaults.set(kept, forKey: Self.defaultsKey)
        defaults.set(keptMachines.mapValues { [$0.id, $0.name] }, forKey: Self.machinesKey)
    }

    /// A page installed for tab `key` with `store`: recorded when the store
    /// is a Cloud proxy store (a popup or duplicate of a proxied page).
    package func adopt(store: BrowserMachineStore?, key: String) {
        guard let store, live[key] == nil, cloudKeys.contains(store.machineKey) else { return }
        record(key, store: store)
    }

    package func isProxied(_ key: String) -> Bool {
        live[key] != nil || kept.contains(key)
    }

    /// `address`, the favicon of tab `key`, when the app may fetch it itself:
    /// nil for a loopback icon of a remote store (a remote-localhost page or a
    /// proxied tab), which would load from this Mac (URL.isAppFetchableFavicon).
    package func appFetchableFavicon(_ address: String?, key: String, page: (any BrowserTab)?) -> String? {
        let remote = (page as? CEFTab)?.machineStore != nil || isProxied(key)
        guard let address, let url = URL(string: address) else { return address }
        return url.isAppFetchableFavicon(remoteStore: remote) ? address : nil
    }

    /// `plan` as the cache's configuration hook: nil (a blank page) for a
    /// blocked tab, `otherwise` for a tab that is not proxied.
    package func configuration(for key: String, url: URL?, base: BrowserTabConfiguration,
                       otherwise: () async -> BrowserTabConfiguration?) async -> BrowserTabConfiguration? {
        switch plan(for: key, url: url, base: base) {
        case .configured(let configuration): return configuration
        case .notProxied: return await otherwise()
        case .blocked:
            // Restored after a relaunch: its machine's route is fetched again on the first request.
            guard let machine = keptMachines[key], let restore, let store = await restore(machine) else { return nil }
            storeMachines[store.machineKey] = machine
            if live[key] == nil { record(key, store: store) }
            guard case .configured(let configuration) = plan(for: key, url: url, base: base) else { return nil }
            return configuration
        }
    }

    /// The Chromium configuration of tab `key` showing `url`: a loopback
    /// URL (or none) keeps the proxied store and may not leave loopback; any
    /// other URL uses the profile's store and may not reach loopback.
    package func plan(for key: String, url: URL?, base: BrowserTabConfiguration) -> Plan {
        let loopback = url.map { LoopbackHost(url: $0)?.isLoopback == true } ?? true
        guard let store = live[key] else {
            guard kept.contains(key) else { return .notProxied }
            // A kept tab the person took to a web page loads it in the profile's store, as when live.
            guard !loopback else { return .blocked }
            var configuration = base
            configuration.machineStore = nil
            configuration.navigationGuard = .noLoopback
            return .configured(configuration)
        }
        var configuration = base
        if loopback {
            configuration.machineStore = store
            configuration.navigationGuard = .loopbackOnly
        } else {
            configuration.machineStore = nil
            configuration.navigationGuard = .noLoopback
        }
        return .configured(configuration)
    }
}

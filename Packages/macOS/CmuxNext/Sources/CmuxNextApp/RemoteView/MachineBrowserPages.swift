import CmuxNextBrowser
import CmuxNextDaemon
import Foundation

/// Tabs whose page runs on another machine (`MachineBrowserRecord`,
/// cx-2cob slice 1), served for `cache`. Until a machine has a browser
/// host the tab shows `MachineBrowserPageTab`: why, the typed address, Open
/// Locally Instead (this Mac's page in place, slice 1a) and Retry.
@MainActor
struct MachineBrowserPages {
    let cache: TabContentCache

    /// The record URL of a tab of another machine's tree that names that
    /// machine (never another one); nil otherwise.
    func recordURL(_ tab: TabModel) -> URL? {
        guard let services = cache.pageRequests.services else { return nil }
        let daemon = services.machines.daemon(forTab: tab)
        guard !daemon.isLocal else { return nil }
        return MachineBrowserRecord.owned(tab.url, byMachine: daemon.machineID)?.url
    }

    /// The not-ready page for `record` in tab `key`.
    func makePage(_ record: MachineBrowserRecord, key: String, engine: BrowserEngineKind,
                  profile: BrowserProfileID) -> MachineBrowserPageTab? {
        guard let services = cache.pageRequests.services else { return nil }
        let machines = services.machines
        return MachineBrowserPageTab(
            id: BrowserTabID(rawValue: key), engine: engine, profile: profile, record: record,
            state: { [weak machines] in
                let name = machines?.machineName(record.machine) ?? record.machine
                let daemon = machines?.daemon(machine: record.machine)
                return .resolve(name: name, isCloud: machines?.session(record.machine) != nil,
                                connected: daemon?.connection != nil, hostReady: false)
            },
            openLocally: { [weak cache] url in
                guard let cache else { return }
                MachineBrowserPages(cache: cache).openLocally(key, machine: record.machine, url: url)
            })
    }

    /// Open Locally Instead: this Mac's page in place of the not-ready page,
    /// at the waiting address; the page says it runs on this Mac. Its record
    /// then names that address (the record writer), so the tab stays local.
    func openLocally(_ key: String, machine: String, url: URL?) {
        let name = cache.pageRequests.services?.machines.machineName(machine) ?? machine
        cache.browserTabs.setNotice(RemoteStrings.browserRunsOnThisMac(name), forKey: key)
        guard let target = url ?? URL(string: BrowserNewTabPage.blankURL) else { return }
        cache.leaveAppPage(key, to: target)
    }

    /// Open on <machine>: the tab's page becomes its machine's browser page
    /// at the address it shows now.
    func openOnMachine(_ key: String, machine: String) {
        let current = cache.browsers[key]?.tab.state.url
        let record = MachineBrowserRecord(machine: machine, initialURL: current)
        guard let page = makePage(record, key: key, engine: .webkit, profile: cache.browserProfile?(key) ?? .default) else { return }
        cache.swapPage(key, with: page)
    }

    /// A session-local tab (no daemon record) opened on a machine.
    func page(key: String, url: URL?, profile: BrowserProfileID) -> MachineBrowserPageTab? {
        guard let record = url.flatMap(MachineBrowserRecord.init(url:)),
              cache.pageRequests.services?.machines.daemon(machine: record.machine) != nil else { return nil }
        return makePage(record, key: key, engine: .webkit, profile: profile)
    }

    /// A new page's machine chip: none on a machine browser page (it runs there).
    func wireChip(_ entry: BrowserEntry, page: any BrowserTab, key: String) {
        entry.chrome.machineBadge = page is MachineBrowserPageTab ? nil : { [weak cache] url in cache?.machineBadge?(key, url) }
    }
}

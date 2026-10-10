import CmuxNextBrowser
import CmuxNextDaemon
import Foundation
#if DEBUG
import CmuxNextRemoteBrowser
#endif

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
        let hosts = services.machineBrowserHosts
        let page = MachineBrowserPageTab(
            id: BrowserTabID(rawValue: key), engine: engine, profile: profile, record: record,
            state: { [weak machines, weak hosts] in
                let name = machines?.machineName(record.machine) ?? record.machine
                let daemon = machines?.daemon(machine: record.machine)
                return .resolve(name: name, isCloud: machines?.session(record.machine) != nil,
                                connected: daemon?.connection != nil, installed: hosts?.installed(record.machine))
            },
            openLocally: { [weak cache] url in
                guard let cache else { return }
                MachineBrowserPages(cache: cache).openLocally(key, machine: record.machine, url: url)
            })
        #if DEBUG
        page.onStart = { [weak cache, weak page] in
            guard let cache, let page else { return }
            MachineBrowserPages(cache: cache).start(page, key: key, profile: profile)
        }
        if services.machines.daemon(machine: record.machine)?.connection != nil, hosts.installed(record.machine) != false {
            start(page, key: key, profile: profile)
        }
        #endif
        return page
    }

    #if DEBUG
    /// Starts the machine's browser for `page`; once it listens, the tab's
    /// page becomes the streamed page (`RemoteBrowserPages.machineTab`). A
    /// failure stays on the not-ready page with its reason and Retry.
    func start(_ page: MachineBrowserPageTab, key: String, profile: BrowserProfileID) {
        guard let services = cache.pageRequests.services else { return }
        let machine = page.record.machine
        let name = services.machines.machineName(machine) ?? machine
        guard services.machines.daemon(machine: machine)?.connection != nil else {
            page.phase = nil
            return
        }
        page.phase = .starting(name)
        let hosts = services.machineBrowserHosts
        // task-owner: one browser start; ends with its answer (the daemon's deadline bounds it).
        Task { [weak cache, weak page] in
            let result = await hosts.start(machine, url: page?.queuedURL)
            guard let cache, let page, cache.browsers[key]?.tab === page else {
                // The tab closed or changed meanwhile: nothing shows this browser.
                if case let .success(runtime) = result { hosts.stop(machine, runtime: runtime.runtime) }
                return
            }
            switch result {
            case let .success(runtime):
                guard let tab = RemoteBrowserPages.machineTab(key: key, profile: profile, machine: machine, runtime: runtime,
                                                               initialURL: page.queuedURL, services: services) else {
                    hosts.stop(machine, runtime: runtime.runtime)
                    page.phase = .failed(name, RemoteBrowserStrings.hostDidNotStart)
                    return
                }
                cache.swapPage(key, with: tab)
            case .failure(.notInstalled):
                page.phase = nil
            case .failure(.unsupported):
                page.phase = .tooOld(name)
            case .failure(.unavailable) where services.machines.daemon(machine: machine)?.connection == nil:
                page.phase = nil
            case let .failure(error):
                page.phase = .failed(name, error.description)
            }
        }
    }
    #endif

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
        var onMachine = page is MachineBrowserPageTab
        #if DEBUG
        onMachine = onMachine || RemoteBrowserPages.runsOnMachine(key)
        #endif
        entry.chrome.machineBadge = onMachine ? nil : { [weak cache] url in cache?.machineBadge?(key, url) }
    }
}

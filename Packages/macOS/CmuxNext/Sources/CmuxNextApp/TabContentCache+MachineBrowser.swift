import CmuxNextBrowser
import CmuxNextDaemon
import Foundation

/// Tabs whose page runs on another machine (`MachineBrowserRecord`,
/// cx-2cob slice 1). Until a machine has a browser host the tab shows
/// `MachineBrowserPageTab`: why, the typed address, Open Locally Instead
/// (this Mac's page in place, slice 1a) and Retry.
extension TabContentCache {
    /// The record URL of a tab of another machine's tree that names that
    /// machine (never another one); nil otherwise.
    func machineRecordURL(_ tab: TabModel) -> URL? {
        guard let services = pageRequests.services else { return nil }
        let daemon = services.machines.daemon(forTab: tab)
        guard !daemon.isLocal else { return nil }
        return MachineBrowserRecord.owned(tab.url, byMachine: daemon.machineID)?.url
    }

    /// The not-ready page for `record` in tab `key`.
    func makeMachinePage(_ record: MachineBrowserRecord, key: String, engine: BrowserEngineKind,
                         profile: BrowserProfileID) -> MachineBrowserPageTab? {
        guard let services = pageRequests.services else { return nil }
        let machines = services.machines
        return MachineBrowserPageTab(
            id: BrowserTabID(rawValue: key), engine: engine, profile: profile, record: record,
            state: { [weak machines] in
                let name = machines?.machineName(record.machine) ?? record.machine
                let daemon = machines?.daemon(machine: record.machine)
                return .resolve(name: name, isCloud: machines?.session(record.machine) != nil,
                                connected: daemon?.connection != nil, hostReady: false)
            },
            openLocally: { [weak self] url in self?.openMachineTabLocally(key, machine: record.machine, url: url) })
    }

    /// Open Locally Instead: this Mac's page in place of the not-ready page,
    /// at the waiting address; the page says it runs on this Mac. Its record
    /// then names that address (the record writer), so the tab stays local.
    func openMachineTabLocally(_ key: String, machine: String, url: URL?) {
        let name = pageRequests.services?.machines.machineName(machine) ?? machine
        browserTabs.setNotice(RemoteStrings.browserRunsOnThisMac(name), forKey: key)
        guard let target = url ?? URL(string: BrowserNewTabPage.blankURL) else { return }
        leaveAppPage(key, to: target)
    }

    /// A session-local tab (no daemon record) opened on a machine.
    func machinePage(key: String, url: URL?, profile: BrowserProfileID) -> MachineBrowserPageTab? {
        guard let record = url.flatMap(MachineBrowserRecord.init(url:)),
              pageRequests.services?.machines.daemon(machine: record.machine) != nil else { return nil }
        return makeMachinePage(record, key: key, engine: .webkit, profile: profile)
    }
}

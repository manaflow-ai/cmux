import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDaemon
import Foundation

extension AppServices {
    /// A pane or tab belongs to its own machine's daemon (cx-2cob): the
    /// browser tab service resolves both through the registry. The registry
    /// does not hold the cache, so the closures make no cycle.
    /// The omnibar chip of browser tab `key` at `url`: the machine whose
    /// localhost it sees (remote-localhost.md 6), else "This Mac" for a tab
    /// of another machine's workspace that runs here (cx-whr7: the page
    /// notice sits under a Chromium page's child window; the chip does not).
    func browserMachineBadge(key: String, url: URL?) -> (text: String, help: String)? {
        if let tab = remoteLocalhost.tab(id: key) {
            let engine: BrowserEngineKind = tab.browserEngine == BrowserEngineTag.cef.rawValue ? .cef : .webkit
            if let badge = remoteLocalhost.badge(for: tab, url: url, engine: engine) { return badge }
        }
        // A machine browser page runs (or waits) on the machine, whatever address it shows.
        guard !MachineBrowserRecord.matches(url), !(cache.existingBrowser(key)?.tab is MachineBrowserPageTab),
              let daemon = daemon(ofBrowserTab: key), !daemon.isLocal else { return nil }
        let name = machines.machineName(daemon.machineID) ?? daemon.machineID
        return (MachineBrowserStrings.thisMac, RemoteStrings.browserRunsOnThisMac(name))
    }

    /// The daemon of browser tab `key`: its record's, else the pane that
    /// holds it as a session-local tab.
    func daemon(ofBrowserTab key: String) -> DaemonService? {
        if let tab = cache.tabModel(key) { return machines.daemon(forTab: tab) }
        for window in windows.controllers {
            for pane in window.content?.panes.values.map({ $0 }) ?? []
            where window.state.localBrowserTabs[pane.paneKey]?.contains(where: { $0.id == key }) == true {
                return pane.daemon
            }
        }
        return nil
    }

    /// The This Mac chip's menu: Open on <machine> (`browser.openOnMachine`).
    func machineBadgeMenu(key: String) -> NSMenu? {
        guard let daemon = daemon(ofBrowserTab: key), !daemon.isLocal else { return nil }
        let name = machines.machineName(daemon.machineID) ?? daemon.machineID
        guard let item = registry.makeMenuItem(for: "browser.openOnMachine") else { return nil }
        item.title = MachineBrowserStrings.openOn(name)
        let menu = NSMenu()
        menu.addItem(item)
        return menu
    }

    /// `browser.openOnMachine`: the tab's page moves to its machine (the
    /// machine browser page: running there, or why not yet).
    func openTabOnMachine(key: String) -> Bool {
        guard let daemon = daemon(ofBrowserTab: key), !daemon.isLocal else { return false }
        MachineBrowserPages(cache: cache).openOnMachine(key, machine: daemon.machineID)
        return true
    }

    func attachMachineBadgeMenu(_ entry: BrowserEntry) {
        guard let key = entry.chrome.addressBar.tabKey else { return }
        entry.chrome.addressBar.machineBadgeMenu = { [weak self] in self?.machineBadgeMenu(key: key) }
    }

    func wireBrowserTabMachines() {
        let machines = machines
        let browserTabs = cache.browserTabs
        browserTabs.daemonForPane = { pane in machines.daemon(forPane: pane) }
        browserTabs.daemonForTab = { tab in machines.daemon(forTab: tab) }
        browserTabs.daemons = { machines.daemons }
        browserTabs.machineName = { daemon in machines.machineName(daemon.machineID) ?? daemon.machineID }
        // Built now so it reads each machine's browser status when the machine connects.
        let hosts = machineBrowserHosts
        browserTabs.browserHostAvailable = { [weak hosts] machine in hosts?.available(machine) ?? false }
        // A forgotten machine's forwarding connection closes, so its browser runtimes stop.
        let localhost = remoteLocalhost
        machines.onDaemonRemoved = { [weak localhost] daemon in localhost?.closeClient(of: daemon) }
        browserTabs.isIncognitoPane = { [weak self] pane in
            guard let self, let workspace = machines.daemon(forPane: pane).store.workspace(containing: pane.handle)?.id else { return false }
            return windows.isIncognito(workspace: workspace)
        }
    }
}

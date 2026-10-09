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
        guard !MachineBrowserRecord.matches(url), let daemon = daemon(ofBrowserTab: key), !daemon.isLocal else { return nil }
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

    func wireBrowserTabMachines() {
        let machines = machines
        let browserTabs = cache.browserTabs
        browserTabs.daemonForPane = { pane in machines.daemon(forPane: pane) }
        browserTabs.daemonForTab = { tab in machines.daemon(forTab: tab) }
        browserTabs.daemons = { machines.daemons }
        browserTabs.machineName = { daemon in machines.machineName(daemon.machineID) ?? daemon.machineID }
        browserTabs.isIncognitoPane = { [weak self] pane in
            guard let self, let workspace = machines.daemon(forPane: pane).store.workspace(containing: pane.handle)?.id else { return false }
            return windows.isIncognito(workspace: workspace)
        }
    }
}

import CmuxNextDaemon

extension AppServices {
    /// A pane or tab belongs to its own machine's daemon (cx-2cob): the
    /// browser tab service resolves both through the registry. The registry
    /// does not hold the cache, so the closures make no cycle.
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

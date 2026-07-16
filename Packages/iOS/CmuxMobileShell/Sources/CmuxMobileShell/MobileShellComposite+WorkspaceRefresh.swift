extension MobileShellComposite {
    /// Refresh the local computer rows plus the foreground Mac without dialing secondary Macs.
    public func refreshComputersScreen() async {
        await loadPairedMacs()
        guard connectionState == .connected, remoteClient != nil else { return }
        if let inFlight = pullToRefreshTask {
            _ = await inFlight.value
            return
        }
        _ = await reloadWorkspaceListFromMac()
    }

    /// Refresh the foreground Mac workspace list and re-aggregate secondary Macs.
    public func refreshWorkspaces() async {
        _ = await refreshWorkspacesAuthoritatively()
    }

    /// Refresh workspaces and report whether a fresh foreground response was applied.
    func refreshWorkspacesAuthoritatively() async -> Bool {
        guard connectionState == .connected, remoteClient != nil else { return false }
        if let inFlight = pullToRefreshTask {
            return await inFlight.value
        }
        let task = Task { @MainActor [weak self] in
            defer { self?.pullToRefreshTask = nil }
            guard let self else { return false }
            let foregroundRefreshSucceeded = await self.reloadWorkspaceListFromMac()
            if self.multiMacAggregationEnabled {
                await self.refreshSecondaryMacWorkspaces()
            }
            return foregroundRefreshSucceeded
        }
        pullToRefreshTask = task
        return await task.value
    }
}

extension MobileShellComposite {
    /// Starts a foreground read after a mutation acknowledgement. An older pull
    /// may contain the pre-mutation hierarchy, so it must settle before this read.
    func refreshForegroundWorkspaceListAfterMutation() async -> Bool {
        advanceForegroundWorkspaceListMutationEpoch()
        if let inFlight = pullToRefreshTask {
            _ = await inFlight.value
        }
        guard connectionState == .connected, remoteClient != nil else { return false }
        return await reloadWorkspaceListFromMac()
    }

    /// Invalidates foreground list reads that started before a mutation response.
    func advanceForegroundWorkspaceListMutationEpoch() {
        foregroundWorkspaceListMutationEpoch &+= 1
    }
}

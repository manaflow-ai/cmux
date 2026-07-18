public import CmuxMobileShellModel

extension MobileShellComposite {
    /// Reconciles the terminal hierarchy for one workspace after an acknowledged
    /// mutation could not refresh automatically.
    @discardableResult
    public func refreshTerminalHierarchy(workspaceID: MobileWorkspacePreview.ID) async -> Bool {
        await refreshAfterWorkspaceMutation(workspaceMutationTarget(for: workspaceID))
    }

    /// Re-syncs one mutation target before the caller clears optimistic state.
    func refreshAfterWorkspaceMutation(_ target: WorkspaceMutationTarget) async -> Bool {
        if target.isForeground {
            let targetOwnerKey = workspaceFocusOwnerKey(macID: target.macDeviceID)
            let foregroundOwnerKey = workspaceFocusOwnerKey(macID: foregroundMacDeviceID)
            guard target.client === remoteClient,
                  targetOwnerKey == foregroundOwnerKey else { return false }
            return await refreshForegroundWorkspaceListAfterMutation()
        }
        guard let macID = target.macDeviceID,
              let subscription = secondaryMacSubscriptions[macID],
              subscription.client === target.client else { return false }
        let displayName = workspacesByMac[macID]?.displayName
        let targetGeneration = subscription.refreshStartedGeneration &+ 1
        subscription.refreshPending = true
        guard var refreshTask = scheduleSecondaryRefresh(
            macID: macID,
            client: subscription.client,
            displayName: displayName
        ) else { return false }
        while secondaryMacSubscriptions[macID] === subscription,
              subscription.refreshFinishedGeneration < targetGeneration {
            await refreshTask.value
            guard secondaryMacSubscriptions[macID] === subscription,
                  subscription.refreshFinishedGeneration < targetGeneration else { break }
            guard let nextTask = subscription.refreshTask ?? scheduleSecondaryRefresh(
                macID: macID,
                client: subscription.client,
                displayName: displayName
            ) else { return false }
            refreshTask = nextTask
        }
        return secondaryMacSubscriptions[macID] === subscription
            && subscription.refreshCompletedGeneration >= targetGeneration
    }
}

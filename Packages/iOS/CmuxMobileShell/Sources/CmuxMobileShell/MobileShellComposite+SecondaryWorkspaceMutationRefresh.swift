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
            guard target.client === remoteClient,
                  target.macDeviceID == foregroundMacDeviceID else { return false }
            return await refreshForegroundWorkspaceListAfterMutation()
        }
        guard let macID = target.macDeviceID,
              let subscription = secondaryMacSubscriptions[macID] else { return false }
        let displayName = workspacesByMac[macID]?.displayName
        let targetGeneration = subscription.refreshStartedGeneration &+ 1
        subscription.refreshPending = true
        scheduleSecondaryRefresh(
            macID: macID,
            client: subscription.client,
            displayName: displayName
        )
        while secondaryMacSubscriptions[macID] === subscription,
              subscription.refreshFinishedGeneration < targetGeneration {
            guard let refreshTask = subscription.refreshTask else {
                scheduleSecondaryRefresh(
                    macID: macID,
                    client: subscription.client,
                    displayName: displayName
                )
                continue
            }
            await refreshTask.value
        }
        return secondaryMacSubscriptions[macID] === subscription
            && subscription.refreshCompletedGeneration >= targetGeneration
    }
}

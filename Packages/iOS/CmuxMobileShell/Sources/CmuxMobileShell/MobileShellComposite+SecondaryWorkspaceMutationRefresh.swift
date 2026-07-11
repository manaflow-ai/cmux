internal import CmuxMobileShellModel

extension MobileShellComposite {
    /// Re-syncs one mutation target before the caller clears optimistic state.
    func refreshAfterWorkspaceMutation(_ target: WorkspaceMutationTarget) async {
        if target.isForeground {
            await refreshWorkspaces()
            return
        }
        guard let macID = target.macDeviceID,
              let subscription = secondaryMacSubscriptions[macID] else { return }
        let displayName = workspacesByMac[macID]?.displayName
        let targetGeneration = subscription.refreshStartedGeneration &+ 1
        subscription.refreshPending = true
        scheduleSecondaryRefresh(
            macID: macID,
            client: subscription.client,
            displayName: displayName
        )
        while secondaryMacSubscriptions[macID] === subscription,
              subscription.refreshCompletedGeneration < targetGeneration {
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
    }
}

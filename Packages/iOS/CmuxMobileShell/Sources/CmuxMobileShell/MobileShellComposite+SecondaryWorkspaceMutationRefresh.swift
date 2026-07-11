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
        let previews = await fetchSecondaryWorkspaces(
            on: subscription.client,
            macDeviceID: macID
        )
        guard let current = secondaryMacSubscriptions[macID],
              current.client === subscription.client,
              let previews else { return }
        workspacesByMac[macID] = MacWorkspaceState(
            macDeviceID: macID,
            displayName: displayName,
            workspaces: previews,
            status: .connected,
            actionCapabilities: current.actionCapabilities
        )
    }
}

internal import CmuxMobileRPC
internal import CmuxMobileShellModel

extension MobileShellComposite {
    /// Coalesced full-list refresh for a secondary Mac driven by
    /// `workspace.updated` pushes. Each task performs at most one leading and
    /// one trailing pass, then hands any newer request to a fresh bounded task.
    func scheduleSecondaryRefresh(
        macID: String,
        client: MobileCoreRPCClient,
        displayName: String?
    ) {
        guard let subscription = secondaryMacSubscriptions[macID],
              subscription.client === client else { return }
        guard subscription.refreshTask == nil else {
            subscription.refreshPending = true
            return
        }
        subscription.refreshTask = Task { @MainActor [weak self, weak subscription] in
            guard let self, let subscription else { return }
            for _ in 0..<2 {
                subscription.refreshPending = false
                subscription.refreshStartedGeneration &+= 1
                let generation = subscription.refreshStartedGeneration
                let previews = await self.fetchSecondaryWorkspaces(
                    on: client,
                    macDeviceID: macID
                )
                guard self.secondaryMacSubscriptions[macID] === subscription else { return }
                subscription.refreshFinishedGeneration = generation
                if let previews {
                    subscription.refreshCompletedGeneration = generation
                    self.workspacesByMac[macID] = MacWorkspaceState(
                        macDeviceID: macID,
                        displayName: displayName,
                        workspaces: previews,
                        status: .connected,
                        actionCapabilities: subscription.actionCapabilities
                    )
                }
                guard subscription.refreshPending else { break }
            }
            guard self.secondaryMacSubscriptions[macID] === subscription else { return }
            let needsFollowUp = subscription.refreshPending
            subscription.refreshTask = nil
            if needsFollowUp {
                self.scheduleSecondaryRefresh(
                    macID: macID,
                    client: client,
                    displayName: displayName
                )
            }
        }
    }
}

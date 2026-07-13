extension MobileShellComposite {
    /// Scope an authorization eviction to the connection that rejected the
    /// request. A secondary Mac must not force the healthy foreground Mac to
    /// reauthenticate, and a stale request must not tear down its replacement.
    func disconnectForAuthorizationFailureIfNeeded(
        _ error: any Error,
        target: WorkspaceMutationTarget
    ) -> Bool {
        guard Self.shouldDisconnectForAuthorizationFailure(error) else {
            return false
        }
        guard isCurrentWorkspaceMutationTarget(target) else {
            return true
        }
        guard !target.isForeground else {
            return disconnectForAuthorizationFailureIfNeeded(error)
        }
        guard let macID = target.macDeviceID,
              let subscription = secondaryMacSubscriptions[macID] else {
            return true
        }
        secondaryMacSubscriptions[macID] = nil
        subscription.cancel()
        markSecondaryMacUnavailable(macID)
        return true
    }

    /// A request target is a snapshot captured before suspension. Only that
    /// exact connection may mutate connection health after the request resumes.
    func isCurrentWorkspaceMutationTarget(_ target: WorkspaceMutationTarget) -> Bool {
        guard let targetClient = target.client else { return false }
        if target.isForeground {
            return remoteClient === targetClient
        }
        guard let macID = target.macDeviceID,
              let subscription = secondaryMacSubscriptions[macID] else {
            return false
        }
        return subscription.client === targetClient
    }

    func markMacConnectionUnavailableIfNeeded(
        after error: any Error,
        target: WorkspaceMutationTarget
    ) {
        guard target.isForeground, isCurrentWorkspaceMutationTarget(target) else { return }
        markMacConnectionUnavailableIfNeeded(after: error)
    }
}

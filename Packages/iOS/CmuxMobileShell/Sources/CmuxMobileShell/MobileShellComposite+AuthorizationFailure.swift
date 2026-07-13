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
        guard !target.isForeground else {
            return disconnectForAuthorizationFailureIfNeeded(error)
        }
        guard let macID = target.macDeviceID,
              let targetClient = target.client,
              let subscription = secondaryMacSubscriptions[macID],
              subscription.client === targetClient else {
            return true
        }
        secondaryMacSubscriptions[macID] = nil
        subscription.cancel()
        markSecondaryMacUnavailable(macID)
        return true
    }
}

@MainActor
extension MobileShellComposite {
    var storedMacReconnectDeadlineTask: Task<DeadlineRaceOutcome<StoredMacReconnectOutcome>, Never>? {
        storedMacReconnectAttempt?.deadlineTask
    }

    /// All candidate paths consult the same lifecycle and account authority.
    func reconnectAttemptIsCurrent(generation: Int, scope: MobileShellScopeSnapshot) -> Bool {
        !Task.isCancelled && connectionEstablishmentIsAllowed && isSignedIn
            && storedMacReconnectGeneration == generation
            && storedMacReconnectAttempt?.generation == generation
            && storedMacReconnectAttempt?.retirement == nil
            && secondaryAggregationScopeGeneration == scope.generation
            && (identityProvider?.currentUserID ?? scope.userID) == scope.userID
    }

    func suspendStoredMacReconnect() {
        if storedMacReconnectAttempt != nil, pendingInactiveRecoveryTrigger == nil {
            pendingInactiveRecoveryTrigger = .foreground
        }
        storedMacReconnectAttempt?.retire(with: .failed(.cancelled))
        zeroTouchDialRace?.close()
    }

    /// Revoke adoption first, then drain a forced retry against the new generation.
    func retireStoredMacReconnect(_ attempt: StoredMacReconnectAttempt, outcome: StoredMacReconnectOutcome) {
        attempt.retire(with: outcome)
        guard storedMacReconnectAttempt === attempt,
              storedMacReconnectGeneration == attempt.generation else { return }
        zeroTouchDialRace?.close()
        zeroTouchDialRace = nil
        finishStoredMacReconnectAttempt(generation: attempt.generation, supersede: true)
    }

    func invalidateStoredMacReconnectAttempt() {
        storedMacReconnectAttempt?.retire(with: .superseded)
        storedMacReconnectGeneration &+= 1
        abandonedReconnectRecoveryGeneration = nil
        zeroTouchDialRace?.close()
        zeroTouchDialRace = nil
        isReconnectingStoredMac = false
        pendingForcedStoredMacReconnect = false
    }

    /// Finish the stored-Mac reconnect attempt and drain any forced retry that
    /// arrived while the underlying dial was still in flight.
    func finishStoredMacReconnectAttempt(generation: Int, supersede: Bool = false) {
        guard generation == storedMacReconnectGeneration else { return }
        if supersede { storedMacReconnectGeneration &+= 1 }
        isReconnectingStoredMac = false
        didFinishStoredMacReconnectAttempt = true
        // Resolving the visible restoring gate does not retire its operation.
        guard supersede || !storedMacReconnectGenerationsInFlight.contains(generation) else { return }
        let shouldRetry = pendingForcedStoredMacReconnect
        pendingForcedStoredMacReconnect = shouldRetry && isSignedIn && !connectionEstablishmentIsAllowed
        guard shouldRetry, isSignedIn, connectionEstablishmentIsAllowed else { return }
        pendingInactiveRecoveryTrigger = nil
        let stackUserID = lastReconnectStackUserID
        let accountID = stackUserID ?? identityProvider?.currentUserID
        let retryGeneration = storedMacReconnectGeneration
        isReconnectingStoredMac = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard retryGeneration == self.storedMacReconnectGeneration,
                  self.isSignedIn,
                  self.identityProvider?.currentUserID == accountID else { return }
            _ = await self.performStoredMacRetry(
                stackUserID: stackUserID,
                force: true
            )
        }
    }

    func performStoredMacRetry(stackUserID: String?, force: Bool) async -> Bool {
        if let accountID = stackUserID ?? identityProvider?.currentUserID {
            clearTransientAutomaticReconnectBackoff(accountID: accountID)
        }
        isReconnectingStoredMac = true
        return await reconnectActiveMacIfAvailable(stackUserID: stackUserID, force: force)
    }

}

import CMUXMobileCore
import CmuxIrohTransport
import CmuxIrxTransport
import Foundation

@MainActor
extension MobileHostIrxRuntime {
    /// Applies the mobile-host policy to the irx lifecycle. Requests are
    /// serialized so a policy lift cannot start a new endpoint while an older
    /// teardown is still closing its resources.
    func setDesiredActive(_ desired: Bool) {
        desiredActive = desired
        if !desired {
            // Invalidate callbacks and publish the policy stop immediately;
            // the serialized task below completes actor/endpoint teardown.
            generationToken = UUID()
            cancelActivationRetry()
            activationTask?.cancel()
            activationTask = nil
            setActivationState(.inactive)
        }

        desiredActivityGeneration &+= 1
        let generation = desiredActivityGeneration
        let previous = desiredActivityTask
        desiredActivityTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            if desired {
                self.resumeActivationIfNeeded()
            } else {
                await self.deactivate()
            }
            if self.desiredActivityGeneration == generation {
                self.desiredActivityTask = nil
            }
        }
    }

    /// Resumes an authenticated account after a policy stop. Reauthentication
    /// and failed states stay visible until the user explicitly refreshes.
    private func resumeActivationIfNeeded() {
        guard desiredActive,
              activationState == .inactive,
              let accountID = activeAccountID else { return }
        activationRetryFailureCount = 0
        activationUnauthorizedFailureCount = 0
        terminalRecoveryCount = 0
        lastBrokerFailure = nil
        setActivationState(.activating)
        startActivation(accountID: accountID)
    }

    /// Starts an activation through the lifecycle-owned task so sign-out and
    /// account changes can cancel every retry-triggered activation as well.
    func startActivation(accountID: String) {
        cancelActivationRetry()
        activationTask?.cancel()
        activationTask = Task { @MainActor [weak self] in
            await self?.activate(accountID: accountID)
        }
    }

    /// Cancels and forgets the one pending activation recovery task.
    ///
    /// A finished task can remain in its property after any early return, so
    /// the handle alone is not a reliable pending marker. The id is cleared
    /// with it so an older task cannot block a later recovery.
    func cancelActivationRetry() {
        activationRetryTask?.cancel()
        activationRetryTask = nil
        activationRetryID = nil
    }

    func handleAutopilotSuccess(accountID: String, token: UUID) {
        guard generationToken == token, activeAccountID == accountID else { return }
        activationRetryFailureCount = 0
        activationUnauthorizedFailureCount = 0
        terminalRecoveryCount = 0
        setActivationState(.active)
    }

    func setActivationState(
        _ state: IrxHostActivationState,
        failure: IrxBrokerFailure? = nil
    ) {
        activationState = state
        if let failure {
            lastBrokerFailure = failure
        } else if state == .activating || state == .active || state == .inactive {
            lastBrokerFailure = nil
        }
        MobileHostPublicStatusCache.update(
            irxActivationState: state,
            failure: lastBrokerFailure
        )
    }

    /// Chooses the generic backoff count or the independent post-recovery
    /// 401 count, then advances only the counter that belongs to this failure.
    /// This prevents unrelated outages from escalating a later auth race.
    private func activationDecision(
        for failure: IrxBrokerFailure,
        jitterUnitInterval: Double
    ) -> IrxHostActivationPolicy.Decision {
        let isPostRecoveryUnauthorized = failure.statusCode == 401
            && !failure.requiresReauthentication
        let count = isPostRecoveryUnauthorized
            ? activationUnauthorizedFailureCount
            : activationRetryFailureCount
        if isPostRecoveryUnauthorized {
            activationUnauthorizedFailureCount = min(
                activationUnauthorizedFailureCount + 1,
                20
            )
        }
        return activationRetryPolicy.decision(
            for: failure,
            failureCount: count,
            jitterUnitInterval: jitterUnitInterval
        )
    }

    func handleActivationFailure(
        _ failure: IrxBrokerFailure,
        accountID: String,
        token: UUID
    ) async {
        guard generationToken == token, activeAccountID == accountID else { return }
        lastBrokerFailure = failure
        var attributes = failure.journalAttributes
        Self.journal.record("host-runtime", "activation-failed", attributes)
        let diagnosticFailure = failure.requiresReauthentication
            ? DiagnosticFailureKind.authorizationFailed
            : (failure.kind == .transient ? .offline : .policyUnavailable)
        MobileHostIrohRuntime.hostDiagnosticLog.record(
            DiagnosticEvent(
                failure.requiresReauthentication
                    ? .hostAuthenticationFailed : .endpointFailed,
                a: DiagnosticTransportKind.iroh.rawValue,
                b: diagnosticFailure.rawValue
            )
        )
        let decision = activationDecision(
            for: failure,
            jitterUnitInterval: Double.random(in: 0 ... 1)
        )
        switch decision {
        case .reauthenticationRequired:
            cancelActivationRetry()
            setActivationState(.reauthenticationRequired, failure: failure)
            attributes["state"] = IrxHostActivationState
                .reauthenticationRequired.rawValue
            Self.journal.record("host-runtime", "reauthentication-required", attributes)
            await cleanupActivationResources(invalidateGeneration: true)
        case let .retry(policyDelay, retryAfterSeconds):
            let delay = IrxRelayCredentialPolicy.boundedRetryDelay(
                expiresAt: nil,
                now: Date(),
                policyDelay: policyDelay,
                retryAfterSeconds: retryAfterSeconds,
                failureCount: activationRetryFailureCount
            )
            setActivationState(.retrying, failure: failure)
            attributes["delay_s"] = String(Int(delay.rounded()))
            if let retryAfterSeconds {
                attributes["retry_after_s"] = String(retryAfterSeconds)
            }
            Self.journal.record("host-runtime", "activation-retry-scheduled", attributes)
            await cleanupActivationResources(invalidateGeneration: true)
            let retryToken = generationToken
            if failure.statusCode != 401 {
                activationRetryFailureCount = min(activationRetryFailureCount + 1, 20)
            }
            let clock = activationRetryClock
            let deadline = clock.now().addingTimeInterval(delay)
            cancelActivationRetry()
            let retryID = UUID()
            activationRetryID = retryID
            activationRetryTask = Task { @MainActor [weak self] in
                defer {
                    guard let self, self.activationRetryID == retryID else { return }
                    self.activationRetryTask = nil
                    self.activationRetryID = nil
                }
                do {
                    try await clock.sleep(until: deadline)
                } catch {
                    return
                }
                guard let self,
                      !Task.isCancelled,
                      self.generationToken == retryToken,
                      self.activeAccountID == accountID else { return }
                self.startActivation(accountID: accountID)
            }
        case .stopped:
            cancelActivationRetry()
            setActivationState(.failed, failure: failure)
            attributes["state"] = IrxHostActivationState.failed.rawValue
            Self.journal.record("host-runtime", "activation-stopped", attributes)
            await cleanupActivationResources(invalidateGeneration: true)
            scheduleFailedActivationRecovery(failure: failure, accountID: accountID)
        }
    }

    func handleAutopilotFailure(
        _ failure: IrxBrokerFailure,
        disposition: IrxRelayCredentialAutopilot.FailureDisposition,
        accountID: String,
        token: UUID
    ) async {
        guard generationToken == token, activeAccountID == accountID else { return }
        lastBrokerFailure = failure
        Self.journal.record(
            "host-runtime", "activation-failed", failure.journalAttributes)
        MobileHostIrohRuntime.hostDiagnosticLog.record(
            DiagnosticEvent(
                failure.requiresReauthentication
                    ? .hostAuthenticationFailed : .endpointFailed,
                a: DiagnosticTransportKind.iroh.rawValue,
                b: failure.requiresReauthentication
                    ? DiagnosticFailureKind.authorizationFailed.rawValue
                    : (failure.kind == .transient
                        ? DiagnosticFailureKind.offline.rawValue
                        : DiagnosticFailureKind.policyUnavailable.rawValue)
            )
        )
        switch disposition {
        case .advisory:
            // The endpoint remains usable; retain the classified context for
            // the journal/diagnostic ring without changing its active state.
            setActivationState(.active, failure: failure)
        case .retry:
            if failure.operation == .hintRefresh {
                // Hint publication is an optimization; keep the already bound
                // endpoint healthy while the autopilot retries it.
                setActivationState(.active, failure: failure)
                return
            }
            let endpoint = endpointSupervisor
            let broker = brokerService
            let healthy = await endpoint?.isHealthy() ?? false
            let credentials = await broker?.cachedRelayCredentials() ?? []
            guard generationToken == token, activeAccountID == accountID else { return }
            if healthy, credentials.contains(where: { $0.isUsable(at: Date()) }) {
                setActivationState(.active)
            } else {
                setActivationState(.retrying, failure: failure)
            }
        case .terminal:
            let requiresReauthentication = failure.requiresReauthentication
                || failure.statusCode == 401
            if requiresReauthentication {
                cancelActivationRetry()
                setActivationState(.reauthenticationRequired, failure: failure)
                var attributes = failure.journalAttributes
                attributes["state"] = IrxHostActivationState
                    .reauthenticationRequired.rawValue
                Self.journal.record("host-runtime", "reauthentication-required", attributes)
                await cleanupActivationResources(invalidateGeneration: true)
                return
            }
            let currentToken = generationToken
            let endpoint = endpointSupervisor
            let broker = brokerService
            let healthy = await endpoint?.isHealthy() ?? false
            let credentials = await broker?.cachedRelayCredentials() ?? []
            guard generationToken == currentToken,
                  activeAccountID == accountID else { return }
            if healthy, credentials.contains(where: { $0.isUsable(at: Date()) }) {
                setActivationState(.active, failure: failure)
                if !scheduleAutopilotRecovery(
                    failure: failure,
                    accountID: accountID,
                    token: currentToken
                ) {
                    setActivationState(.failed, failure: failure)
                    var attributes = failure.journalAttributes
                    attributes["state"] = IrxHostActivationState.failed.rawValue
                    Self.journal.record(
                        "host-runtime", "activation-stopped", attributes)
                    await cleanupActivationResources(invalidateGeneration: true)
                }
                return
            }
            cancelActivationRetry()
            setActivationState(.failed, failure: failure)
            var attributes = failure.journalAttributes
            attributes["state"] = IrxHostActivationState.failed.rawValue
            Self.journal.record("host-runtime", "activation-stopped", attributes)
            await cleanupActivationResources(invalidateGeneration: true)
            scheduleFailedActivationRecovery(failure: failure, accountID: accountID)
        }
    }

    /// Restarts only credential renewal while a still-healthy endpoint keeps
    /// serving existing sessions after a terminal mint response.
    @discardableResult
    private func scheduleAutopilotRecovery(
        failure: IrxBrokerFailure,
        accountID: String,
        token: UUID
    ) -> Bool {
        guard activationRetryTask == nil else { return true }
        guard terminalRecoveryCount < 3 else {
            if terminalRecoveryCount >= 3 {
                Self.journal.record(
                    "host-runtime", "autopilot-recovery-exhausted",
                    failure.journalAttributes
                )
            }
            return false
        }
        let delay = activationRetryPolicy.retrySchedule.delay(
            failureCount: terminalRecoveryCount,
            retryAfterSeconds: nil,
            jitterUnitInterval: 0
        )
        terminalRecoveryCount += 1
        let clock = activationRetryClock
        let deadline = clock.now().addingTimeInterval(delay)
        var attributes = failure.journalAttributes
        attributes["delay_s"] = String(Int(delay.rounded()))
        Self.journal.record("host-runtime", "autopilot-retry-scheduled", attributes)
        let retryID = UUID()
        activationRetryID = retryID
        activationRetryTask = Task { @MainActor [weak self] in
            defer {
                guard let self, self.activationRetryID == retryID else { return }
                self.activationRetryTask = nil
                self.activationRetryID = nil
            }
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.generationToken == token,
                  self.activeAccountID == accountID else { return }
            await self.autopilot?.kick()
        }
        return true
    }

    /// Keeps non-auth terminal failures recoverable without a tight retry loop.
    /// A later network/auth signal or the Settings refresh can still reset the
    /// ladder and start immediately.
    private func scheduleFailedActivationRecovery(
        failure: IrxBrokerFailure,
        accountID: String
    ) {
        guard activeAccountID == accountID,
              activationRetryTask == nil,
              terminalRecoveryCount < 3 else {
            if terminalRecoveryCount >= 3 {
                Self.journal.record(
                    "host-runtime", "activation-recovery-exhausted",
                    failure.journalAttributes
                )
            }
            return
        }
        let delay = activationRetryPolicy.retrySchedule.delay(
            failureCount: terminalRecoveryCount,
            retryAfterSeconds: nil,
            jitterUnitInterval: 0
        )
        terminalRecoveryCount += 1
        let token = generationToken
        let clock = activationRetryClock
        let deadline = clock.now().addingTimeInterval(delay)
        var attributes = failure.journalAttributes
        attributes["delay_s"] = String(Int(delay.rounded()))
        attributes["state"] = IrxHostActivationState.failed.rawValue
        Self.journal.record("host-runtime", "activation-retry-scheduled", attributes)
        let retryID = UUID()
        activationRetryID = retryID
        activationRetryTask = Task { @MainActor [weak self] in
            defer {
                guard let self, self.activationRetryID == retryID else { return }
                self.activationRetryTask = nil
                self.activationRetryID = nil
            }
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.generationToken == token,
                  self.activeAccountID == accountID else { return }
            self.setActivationState(.activating)
            self.startActivation(accountID: accountID)
        }
    }

    func cleanupActivationResources(invalidateGeneration: Bool = false) async {
        if invalidateGeneration {
            generationToken = UUID()
        }
        acceptLoop?.cancel()
        acceptLoop = nil
        if let autopilot {
            await autopilot.stop()
        }
        autopilot = nil
        if let registry {
            await registry.closeAll(code: .hostShutdown)
        }
        registry = nil
        if let endpointSupervisor {
            await endpointSupervisor.close()
        }
        endpointSupervisor = nil
        brokerService = nil
        localBinding = nil
        hadLiveDiscovery = false
        MobileHostPublicStatusCache.update(irohIdentity: nil)
    }

    func deactivate(preserveReauthentication: Bool = false) async {
        generationToken = UUID()
        cancelActivationRetry()
        activationRetryFailureCount = 0
        activationUnauthorizedFailureCount = 0
        terminalRecoveryCount = 0
        activationTask?.cancel()
        activationTask = nil
        await cleanupActivationResources()
        if preserveReauthentication {
            setActivationState(
                .reauthenticationRequired,
                failure: lastBrokerFailure
            )
        } else {
            setActivationState(.inactive)
        }
        Self.journal.record("host-runtime", "deactivated")
    }
}

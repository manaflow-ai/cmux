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
        let effectiveDesired = desired
            && MobileRemoteControlPolicy.isEnabled
            && Self.isEnabled
        guard desiredActive != effectiveDesired else { return }
        desiredActive = effectiveDesired
        if !effectiveDesired {
            // Invalidate callbacks and publish the policy stop immediately;
            // the serialized task below completes actor/endpoint teardown.
            generationToken = UUID()
            cancelActivationRetry()
            cancelAutopilotRecovery()
            activationTask?.cancel()
            activationTask = nil
            if activationState != .reauthenticationRequired {
                setActivationState(.inactive)
            }
        }

        desiredActivityGeneration &+= 1
        let generation = desiredActivityGeneration
        let previous = desiredActivityTask
        desiredActivityTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            if effectiveDesired {
                self.resumeActivationIfNeeded()
            } else {
                await self.deactivate(
                    preserveReauthentication:
                        self.activationState == .reauthenticationRequired
                )
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
              activationState == .inactive || activationState == .failed,
              let accountID = activeAccountID else { return }
        activationRetryFailureCount = 0
        activationUnauthorizedFailureCount = 0
        activationMissingAuthenticationFailureCount = 0
        terminalRecoveryCount = 0
        lastBrokerFailure = nil
        setActivationState(.activating)
        startActivation(accountID: accountID)
    }

    /// Starts an activation through the lifecycle-owned task so sign-out and
    /// account changes can cancel every retry-triggered activation as well.
    func startActivation(accountID: String) {
        guard desiredActive,
              Self.isEnabled,
              activeAccountID == accountID else { return }
        cancelActivationRetry()
        cancelAutopilotRecovery()
        // Invalidate the previous task synchronously before cancellation. A
        // cancellation can be delivered while that task is parked in a broker
        // call; the token fence keeps its late continuation from publishing.
        generationToken = UUID()
        activationTask?.cancel()
        let activityGeneration = desiredActivityGeneration
        activationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.cleanupActivationResources(invalidateGeneration: false)
            guard self.desiredActive,
                  Self.isEnabled,
                  self.activeAccountID == accountID,
                  self.desiredActivityGeneration == activityGeneration,
                  !Task.isCancelled else { return }
            await self.activate(
                accountID: accountID,
                activityGeneration: activityGeneration
            )
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

    /// Cancels and forgets the independent credential-autopilot kick.
    func cancelAutopilotRecovery() {
        autopilotRecoveryTask?.cancel()
        autopilotRecoveryTask = nil
        autopilotRecoveryID = nil
    }
    func handleAutopilotSuccess(accountID: String, token: UUID) {
        guard generationToken == token,
              activeAccountID == accountID,
              desiredActive,
              Self.isEnabled else { return }
        activationRetryFailureCount = 0
        activationUnauthorizedFailureCount = 0
        activationMissingAuthenticationFailureCount = 0
        terminalRecoveryCount = 0
        cancelAutopilotRecovery()
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
        let settingsPhase: SettingsPhase = switch state {
        case .inactive:
            .idle
        case .activating, .retrying:
            .activating
        case .active:
            .active
        case .failed, .reauthenticationRequired:
            .failed
        }
        setSettingsPhase(settingsPhase)
    }

    /// Chooses the counter that belongs to this failure without mutating it.
    /// The caller advances that counter only after a retry is actually chosen,
    /// so the same pre-increment value drives both policy classification and
    /// expiry-aware delay calculation.
    private func activationFailureCount(for failure: IrxBrokerFailure) -> Int {
        return switch failure.escalationBucket {
        case .unauthorized: activationUnauthorizedFailureCount
        case .missingAuthentication: activationMissingAuthenticationFailureCount
        case .transient: activationRetryFailureCount
        }
    }

    /// Advances only the counter associated with a retryable failure. Keeping
    /// this beside ``activationFailureCount(for:)`` prevents auth and generic
    /// outages from consuming one another's escalation budgets.
    private func advanceActivationFailureCount(for failure: IrxBrokerFailure) {
        switch failure.escalationBucket {
        case .unauthorized:
            activationUnauthorizedFailureCount = min(
                activationUnauthorizedFailureCount + 1, 20)
        case .missingAuthentication:
            activationMissingAuthenticationFailureCount = min(
                activationMissingAuthenticationFailureCount + 1, 20)
        case .transient:
            activationRetryFailureCount = min(activationRetryFailureCount + 1, 20)
        }
    }

    private func activationDecision(
        for failure: IrxBrokerFailure,
        jitterUnitInterval: Double
    ) -> (decision: IrxHostActivationPolicy.Decision, failureCount: Int) {
        let failureCount = activationFailureCount(for: failure)
        return (
            decision: activationRetryPolicy.decision(
                for: failure,
                failureCount: failureCount,
                jitterUnitInterval: jitterUnitInterval
            ),
            failureCount: failureCount
        )
    }

    func handleActivationFailure(
        _ failure: IrxBrokerFailure,
        accountID: String,
        token: UUID
    ) async {
        guard generationToken == token,
              activeAccountID == accountID,
              desiredActive,
              Self.isEnabled else { return }
        lastBrokerFailure = failure
        var attributes = failure.journalAttributes
        Self.journal.record("host-runtime", "activation-failed", attributes)
        let diagnosticFailure = failure.diagnosticFailureKind
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
        switch decision.decision {
        case .reauthenticationRequired:
            cancelActivationRetry()
            cancelAutopilotRecovery()
            setActivationState(.reauthenticationRequired, failure: failure)
            attributes["state"] = IrxHostActivationState
                .reauthenticationRequired.rawValue
            Self.journal.record("host-runtime", "reauthentication-required", attributes)
            await cleanupActivationResources(invalidateGeneration: true)
        case let .retry(policyDelay, retryAfterSeconds):
            let activityGeneration = desiredActivityGeneration
            let delay = credentialPolicy.boundedRetryDelay(
                expiresAt: nil,
                now: Date(),
                policyDelay: policyDelay,
                retryAfterSeconds: retryAfterSeconds,
                failureCount: decision.failureCount
            )
            setActivationState(.retrying, failure: failure)
            attributes["delay_s"] = String(Int(delay.rounded()))
            if let retryAfterSeconds {
                attributes["retry_after_s"] = String(retryAfterSeconds)
            }
            Self.journal.record("host-runtime", "activation-retry-scheduled", attributes)
            await cleanupActivationResources(invalidateGeneration: true)
            // Cleanup suspends while endpoint, registry, and autopilot lanes
            // close. A policy/feature transition can win that suspension; do
            // not arm a retry from the post-cleanup generation in that case.
            guard desiredActive,
                  Self.isEnabled,
                  activeAccountID == accountID,
                  desiredActivityGeneration == activityGeneration,
                  !Task.isCancelled else { return }
            let retryToken = generationToken
            advanceActivationFailureCount(for: failure)
            let clock = activationRetryClock
            let deadline = clock.now().addingTimeInterval(delay)
            cancelActivationRetry()
            cancelAutopilotRecovery()
            let retryID = UUID()
            activationRetryID = retryID
            activationRetryTask = Task { @MainActor [weak self] in
                defer {
                    if let self, self.activationRetryID == retryID {
                        self.activationRetryTask = nil
                        self.activationRetryID = nil
                    }
                }
                do {
                    try await clock.sleep(until: deadline)
                } catch {
                    return
                }
                guard let self,
                      !Task.isCancelled,
                      self.desiredActive,
                      Self.isEnabled,
                      self.generationToken == retryToken,
                      self.activeAccountID == accountID,
                      self.desiredActivityGeneration == activityGeneration else { return }
                self.startActivation(accountID: accountID)
            }
        case .stopped:
            cancelActivationRetry()
            cancelAutopilotRecovery()
            setActivationState(.failed, failure: failure)
            attributes["state"] = IrxHostActivationState.failed.rawValue
            Self.journal.record("host-runtime", "activation-stopped", attributes)
            await cleanupActivationResources(invalidateGeneration: true)
            guard desiredActive,
                  Self.isEnabled,
                  activeAccountID == accountID,
                  !Task.isCancelled else { return }
            scheduleFailedActivationRecovery(failure: failure, accountID: accountID)
        }
    }

    func handleAutopilotFailure(
        _ failure: IrxBrokerFailure,
        disposition: IrxRelayCredentialAutopilot.FailureDisposition,
        accountID: String,
        token: UUID
    ) async {
        guard generationToken == token,
              activeAccountID == accountID,
              desiredActive,
              Self.isEnabled else { return }
        lastBrokerFailure = failure
        Self.journal.record(
            "host-runtime", "activation-failed", failure.journalAttributes)
        MobileHostIrohRuntime.hostDiagnosticLog.record(
            DiagnosticEvent(
                failure.requiresReauthentication
                    ? .hostAuthenticationFailed : .endpointFailed,
                a: DiagnosticTransportKind.iroh.rawValue,
                b: failure.diagnosticFailureKind.rawValue
            )
        )
        let activityGeneration = desiredActivityGeneration
        switch disposition {
        case .advisory:
            // The endpoint remains usable; retain the classified context for
            // the journal/diagnostic ring without changing its active state.
            guard activationState == .active else { return }
            setActivationState(.active, failure: failure)
        case .retry:
            if failure.operation == .hintRefresh {
                // Hint publication is an optimization; keep the already bound
                // endpoint's existing state while the autopilot retries it.
                guard activationState == .active else { return }
                setActivationState(.active, failure: failure)
                return
            }
            let endpoint = endpointSupervisor
            let broker = brokerService
            let healthy = await endpoint?.isHealthy() ?? false
            let credentials = await broker?.cachedRelayCredentials() ?? []
            guard generationToken == token,
                  activeAccountID == accountID,
                  desiredActive,
                  Self.isEnabled else { return }
            if healthy, credentials.contains(where: { $0.isUsable(at: Date()) }) {
                setActivationState(.active)
            } else {
                setActivationState(.retrying, failure: failure)
            }
        case let .terminal(requiresReauthentication):
            if requiresReauthentication {
                cancelActivationRetry()
                cancelAutopilotRecovery()
                setActivationState(.reauthenticationRequired, failure: failure)
                var attributes = failure.journalAttributes
                attributes["state"] = IrxHostActivationState
                    .reauthenticationRequired.rawValue
                Self.journal.record("host-runtime", "reauthentication-required", attributes)
                await cleanupActivationResources(
                    invalidateGeneration: true, stopAutopilot: false)
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
                    await cleanupActivationResources(
                        invalidateGeneration: true, stopAutopilot: false)
                }
                return
            }
            cancelActivationRetry()
            cancelAutopilotRecovery()
            setActivationState(.failed, failure: failure)
            var attributes = failure.journalAttributes
            attributes["state"] = IrxHostActivationState.failed.rawValue
            Self.journal.record("host-runtime", "activation-stopped", attributes)
            await cleanupActivationResources(
                invalidateGeneration: true, stopAutopilot: false)
            guard desiredActive,
                  Self.isEnabled,
                  activeAccountID == accountID,
                  desiredActivityGeneration == activityGeneration,
                  !Task.isCancelled else { return }
            scheduleFailedActivationRecovery(failure: failure, accountID: accountID)
        }
    }

    func cleanupActivationResources(
        invalidateGeneration: Bool = false,
        stopAutopilot: Bool = true,
        expectedToken: UUID? = nil
    ) async {
        guard expectedToken == nil || generationToken == expectedToken else { return }
        let cleanupToken = invalidateGeneration ? UUID() : generationToken
        if invalidateGeneration {
            generationToken = cleanupToken
        }
        acceptLoop?.cancel()
        acceptLoop = nil
        if let controlPlane {
            await controlPlane.stop()
        }
        controlPlane = nil
        // The in-memory directory is generation-scoped. The persisted lease
        // remains available for the next same-account activation unless the
        // auth transition explicitly clears it.
        deviceListBox?.clear()
        deviceListBox = nil
        deviceListStore = nil
        if stopAutopilot, let autopilot {
            await autopilot.stop()
        }
        guard generationToken == cleanupToken else { return }
        autopilot = nil
        if let registry {
            await registry.closeAll(code: .hostShutdown)
        }
        guard generationToken == cleanupToken else { return }
        registry = nil
        if let endpointSupervisor {
            await endpointSupervisor.close()
        }
        guard generationToken == cleanupToken else { return }
        endpointSupervisor = nil
        brokerService = nil
        localBinding = nil
        hadLiveDiscovery = false
        // Route ownership is explicit because the feature flag can change
        // while this asynchronous teardown is still unwinding.
        guard generationToken == cleanupToken else { return }
        MobileHostPublicStatusCache.update(irohIdentity: nil, owner: .irx)
    }

    func deactivate(preserveReauthentication: Bool = false) async {
        generationToken = UUID()
        cancelActivationRetry()
        cancelAutopilotRecovery()
        activationRetryFailureCount = 0
        activationUnauthorizedFailureCount = 0
        activationMissingAuthenticationFailureCount = 0
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
        setSettingsPhase(
            preserveReauthentication ? .failed : .idle
        )
        Self.journal.record("host-runtime", "deactivated")
    }
}

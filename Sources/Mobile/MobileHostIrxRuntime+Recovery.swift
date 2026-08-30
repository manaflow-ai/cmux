import CMUXMobileCore
import CmuxIrohTransport
import CmuxIrxTransport
import Foundation

@MainActor
extension MobileHostIrxRuntime {
    /// Starts an activation through the lifecycle-owned task so sign-out and
    /// account changes can cancel every retry-triggered activation as well.
    func startActivation(accountID: String) {
        activationTask?.cancel()
        activationTask = Task { @MainActor [weak self] in
            await self?.activate(accountID: accountID)
        }
    }

    func handleAutopilotSuccess(accountID: String, token: UUID) {
        guard generationToken == token, activeAccountID == accountID else { return }
        activationRetryFailureCount = 0
        activationUnauthorizedFailureCount = 0
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
        } else {
            activationUnauthorizedFailureCount = 0
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
            activationRetryTask?.cancel()
            activationRetryTask = nil
            setActivationState(.reauthenticationRequired, failure: failure)
            attributes["state"] = IrxHostActivationState
                .reauthenticationRequired.rawValue
            Self.journal.record("host-runtime", "reauthentication-required", attributes)
            await cleanupActivationResources()
        case let .retry(policyDelay, retryAfterSeconds):
            let delay = IrxRelayCredentialPolicy.boundedRetryDelay(
                expiresAt: nil,
                now: Date(),
                policyDelay: policyDelay,
                retryAfterSeconds: retryAfterSeconds
            )
            setActivationState(.retrying, failure: failure)
            attributes["delay_s"] = String(Int(delay.rounded()))
            if let retryAfterSeconds {
                attributes["retry_after_s"] = String(retryAfterSeconds)
            }
            Self.journal.record("host-runtime", "activation-retry-scheduled", attributes)
            await cleanupActivationResources()
            activationRetryFailureCount = min(activationRetryFailureCount + 1, 20)
            let clock = activationRetryClock
            let deadline = clock.now().addingTimeInterval(delay)
            activationRetryTask?.cancel()
            activationRetryTask = Task { @MainActor [weak self] in
                do {
                    try await clock.sleep(until: deadline)
                } catch {
                    return
                }
                guard let self,
                      !Task.isCancelled,
                      self.generationToken == token,
                      self.activeAccountID == accountID else { return }
                self.activationRetryTask = nil
                self.startActivation(accountID: accountID)
            }
        case .stopped:
            activationRetryTask?.cancel()
            activationRetryTask = nil
            setActivationState(.failed, failure: failure)
            attributes["state"] = IrxHostActivationState.failed.rawValue
            Self.journal.record("host-runtime", "activation-stopped", attributes)
            await cleanupActivationResources()
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
        case .retry:
            if failure.operation == .hintRefresh {
                // Hint publication is an optimization; keep the already bound
                // endpoint healthy while the autopilot retries it.
                setActivationState(.active)
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
                activationRetryTask?.cancel()
                activationRetryTask = nil
                setActivationState(.reauthenticationRequired, failure: failure)
                var attributes = failure.journalAttributes
                attributes["state"] = IrxHostActivationState
                    .reauthenticationRequired.rawValue
                Self.journal.record("host-runtime", "reauthentication-required", attributes)
                await cleanupActivationResources()
                return
            }
            activationRetryTask?.cancel()
            activationRetryTask = nil
            setActivationState(.failed, failure: failure)
            var attributes = failure.journalAttributes
            attributes["state"] = IrxHostActivationState.failed.rawValue
            Self.journal.record("host-runtime", "activation-stopped", attributes)
            await cleanupActivationResources()
        }
    }

    func cleanupActivationResources() async {
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
        activationRetryTask?.cancel()
        activationRetryTask = nil
        activationRetryFailureCount = 0
        activationUnauthorizedFailureCount = 0
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

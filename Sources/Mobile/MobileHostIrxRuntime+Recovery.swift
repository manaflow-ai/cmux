import CMUXMobileCore
import CmuxIrohTransport
import CmuxIrxTransport
import Foundation

@MainActor
extension MobileHostIrxRuntime {
    func handleAutopilotSuccess(accountID: String, token: UUID) {
        guard generationToken == token, activeAccountID == accountID else { return }
        activationRetryFailureCount = 0
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
        publishIrxSettingsUpdate()
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
        let decision = activationRetryPolicy.decision(
            for: failure,
            failureCount: activationRetryFailureCount,
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
        case let .retry(delay, retryAfterSeconds):
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
                await self.activate(accountID: accountID)
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
        accountID: String,
        token: UUID
    ) async {
        guard generationToken == token, activeAccountID == accountID else { return }
        lastBrokerFailure = failure
        var attributes = failure.journalAttributes
        Self.journal.record("host-runtime", "activation-failed", attributes)
        MobileHostIrohRuntime.hostDiagnosticLog.record(
            DiagnosticEvent(
                failure.requiresReauthentication
                    ? .hostAuthenticationFailed : .endpointFailed,
                a: DiagnosticTransportKind.iroh.rawValue,
                b: failure.requiresReauthentication
                    ? DiagnosticFailureKind.authorizationFailed.rawValue
                    : DiagnosticFailureKind.offline.rawValue
            )
        )
        if failure.requiresReauthentication {
            activationRetryTask?.cancel()
            activationRetryTask = nil
            setActivationState(.reauthenticationRequired, failure: failure)
            attributes["state"] = IrxHostActivationState
                .reauthenticationRequired.rawValue
            Self.journal.record("host-runtime", "reauthentication-required", attributes)
            await cleanupActivationResources()
        } else {
            setActivationState(.retrying, failure: failure)
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

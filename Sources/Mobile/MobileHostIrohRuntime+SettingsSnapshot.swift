import CMUXMobileCore
import CmuxIrohTransport
import CmuxIrxTransport
import Foundation

@MainActor
extension MobileHostIrohRuntime {
    /// Marks the activation owner before AuthCoordinator can publish a
    /// signed-out identity during a broker-triggered refresh.
    func markBrokerAuthenticationRefreshStarted(
        revision: UInt64
    ) {
        guard lifecycleRevision == revision, !signOutIntentActive else {
            return
        }
        pendingBrokerAuthenticationRefreshRevision = revision
    }

    /// Clears the handoff marker after refresh completion. A definitive
    /// rejection intentionally leaves it set until the activation-failure
    /// handler records the operation-specific reauthentication state.
    func completeBrokerAuthenticationRefresh(
        revision: UInt64,
        requiresReauthentication: Bool
    ) {
        guard pendingBrokerAuthenticationRefreshRevision == revision,
              lifecycleRevision == revision else {
            return
        }
        if !requiresReauthentication {
            pendingBrokerAuthenticationRefreshRevision = nil
        }
    }

    /// Maps the legacy runtime's route-publication phase to the shared Mobile
    /// settings lifecycle state without inferring status from cached routes.
    var publishedIrohActivationState: IrxHostActivationState {
        if desiredActive, irohAuthenticationFailure != nil {
            return .reauthenticationRequired
        }
        if desiredActive, failureRecoveryTask != nil {
            return .retrying
        }
        if desiredActive, irohActivationFailure != nil {
            return .failed
        }
        switch routePublicationPhase {
        case .unavailable:
            return .inactive
        case .starting:
            return .activating
        case .active:
            return .active
        }
    }

    /// The definitive broker failure retained for the shared host status
    /// projection. It remains visible after route teardown.
    var publishedIrohBrokerFailure: IrxBrokerFailure? {
        guard desiredActive else { return nil }
        return irohAuthenticationFailure ?? irohActivationFailure
    }

    /// Records a definitive auth rejection from the shared broker client and
    /// stops legacy recovery until the account transitions or the user retries.
    @discardableResult
    func handleIrohActivationFailure(
        _ error: any Error,
        revision: UInt64
    ) async -> Bool {
        let failure = error as? IrxBrokerFailure
            ?? IrxBrokerFailure(operation: .register, error: error)
        guard failure.requiresReauthentication,
              revision == lifecycleRevision else { return false }
        pendingBrokerAuthenticationRefreshRevision = nil
        irohAuthenticationFailure = failure
        irohActivationFailure = failure
        cancelFailureRecovery(resetBackoff: true)
        let failedRuntime = runtime
        runtime = nil
        clearIrohRoutePublication(revision: revision)
        if let failedRuntime {
            await failedRuntime.stop()
        }
        diagnosticLog.record(DiagnosticEvent(
            .hostAuthenticationFailed,
            a: DiagnosticTransportKind.iroh.rawValue
        ))
        publishIrohSettingsUpdate()
        return true
    }

    /// Clears a prior auth failure when a fresh activation is authorized.
    func clearIrohAuthenticationFailure() {
        irohAuthenticationFailure = nil
        irohActivationFailure = nil
    }

    func irohSettingsSnapshot() async -> CmxIrohSettingsSnapshot {
        let service = relayPolicyService
        let effective = await service?.effectivePolicy() ?? relayPolicyEffective
        let diagnostics = await service?.diagnosticsSnapshot() ?? relayPolicyDiagnostics
        let managedPolicy = await service?.managedPolicy() ?? effective?.managedPolicy
        let runtimeState = await runtime?.snapshot().state
        let selectedPath = await runtime?.selectedTransportPath(
            relayPolicy: effective
        ) ?? .unavailable
        let configuration = effective?.requestedConfiguration
        let requested = configuration?.activePreference
        let selectedIDs = configuration?.selectedManagedRelayIDs.isEmpty == false
            ? configuration?.selectedManagedRelayIDs ?? []
            : Set(diagnostics?.selectedRelayIDs ?? [])
        let configuredCredentialIDs = if let service, let activeAccountID {
            await service.configuredCustomCredentialRelayIDs(accountID: activeAccountID)
        } else {
            Optional<Set<String>>.none
        }

        #if DEBUG
        let debugTransportVerificationMode: CmxIrohTransportVerificationMode? =
            transportVerificationMode
        let pathPreference = CmxIrohPathPreference.stored(in: UserDefaults.standard)
        #else
        let debugTransportVerificationMode: CmxIrohTransportVerificationMode? = nil
        let pathPreference: CmxIrohPathPreference = .automatic
        #endif
        let requiresReauthentication = desiredActive
            && irohAuthenticationFailure != nil
        return CmxIrohSettingsSnapshot(
            runtimeStatus: requiresReauthentication
                ? .degraded
                : Self.settingsRuntimeStatus(
                    runtimeState,
                    failure: diagnostics?.failure,
                    selectedPath: selectedPath
                ),
            selectedTransportPath: selectedPath,
            preference: Self.settingsPreference(requested),
            pathPreference: pathPreference,
            managedRelays: managedPolicy?.relays.map { relay in
                CmxIrohSettingsSnapshot.ManagedRelay(
                    id: relay.id,
                    provider: relay.provider,
                    region: relay.region,
                    url: relay.url,
                    isSelected: selectedIDs.contains(relay.id)
                )
            } ?? [],
            customRelays: Self.settingsCustomRelays(
                configuration: configuration,
                configuredCredentialIDs: configuredCredentialIDs
            ),
            policySource: Self.settingsPolicySource(effective),
            policySequence: diagnostics?.policySequence,
            policyExpiresAt: diagnostics?.policyExpiresAt,
            staleRelayIDs: Set(diagnostics?.staleRelayIDs ?? []),
            failureDescription: requiresReauthentication
                ? irohAuthenticationFailure?.diagnosticErrorCode
                : diagnostics?.failure?.rawValue,
            requiresReauthentication: requiresReauthentication,
            debugTransportVerificationMode: debugTransportVerificationMode
        )
    }

    private nonisolated static func settingsRuntimeStatus(
        _ state: CmxIrohHostRuntimeSnapshot.State?,
        failure: CmxIrohRelayPolicyFailure?,
        selectedPath: CmxIrohSelectedTransportPath
    ) -> CmxIrohSettingsSnapshot.RuntimeStatus {
        if failure != nil { return .degraded }
        switch state {
        case .active:
            return CmxIrohSettingsSnapshot.RuntimeStatus(activePath: selectedPath)
        case .starting:
            return .starting
        case .failed, .quarantined:
            return .degraded
        case .inactive, .stopping, .signingOut, nil:
            return .inactive
        }
    }

    private nonisolated static func settingsPreference(
        _ preference: CmxIrohAccountRelayPreference?
    ) -> CmxIrohRelayPreferenceDraft {
        switch preference {
        case .automatic, nil:
            return .automatic
        case let .managed(ids):
            return .managed(ids)
        case .custom:
            return .custom
        }
    }

    private nonisolated static func settingsCustomRelays(
        configuration: CmxIrohAccountRelayConfiguration?,
        configuredCredentialIDs: Set<String>?
    ) -> [CmxIrohSettingsSnapshot.CustomRelay] {
        configuration?.customRelays.map { relay in
            let credentialState: CmxIrohSettingsSnapshot.CredentialState
            if relay.authMode == .none {
                credentialState = .notRequired
            } else if configuredCredentialIDs == nil {
                credentialState = .unavailable
            } else {
                credentialState = configuredCredentialIDs?.contains(relay.id) == true
                    ? .configured
                    : .missing
            }
            return CmxIrohSettingsSnapshot.CustomRelay(
                id: relay.id,
                displayName: relay.displayName ?? relay.id,
                provider: relay.provider,
                region: relay.region,
                url: relay.url,
                authMode: relay.authMode == .staticToken ? .deviceSecret : .none,
                credentialState: credentialState
            )
        } ?? []
    }

    private nonisolated static func settingsPolicySource(
        _ effective: CmxIrohEffectiveRelayPolicy?
    ) -> CmxIrohSettingsSnapshot.PolicySource {
        guard let effective else { return .unavailable }
        return effective.usedCachedPolicy ? .cached : .server
    }
}

extension MobileHostIrohRuntime {
    /// Reads only app-bundled public verification keys. Broker responses never
    /// become trust roots, so a missing or malformed build configuration keeps
    /// dynamic managed policy unavailable instead of accepting an unsigned fleet.
    nonisolated static func relayPolicyTrustRoot(
        infoDictionary: [String: Any]?
    ) -> CmxIrohRelayPolicyTrustRoot? {
        CmxIrohRelayPolicyTrustRoot.appPinned(infoDictionary: infoDictionary)
    }
}

import CMUXMobileCore
import CmuxIrohTransport
import Foundation

@MainActor
extension MobileHostIrohRuntime {
    func irohSettingsSnapshot() async -> CmxIrohSettingsSnapshot {
        let service = relayPolicyService
        let resolvedEffective = await service?.effectivePolicy() ?? relayPolicyEffective
        let endpointEffective = relayPolicyAppliedEffective ?? resolvedEffective
        let diagnostics = await service?.diagnosticsSnapshot() ?? relayPolicyDiagnostics
        let managedPolicy = await service?.managedPolicy() ?? resolvedEffective?.managedPolicy
        let appliedAuthorityRevoked = relayPolicyAppliedFailure == .policyExpired
        let runtimeState = await runtime?.snapshot().state
        let selectedPath = await runtime?.selectedTransportPath(
            relayPolicy: endpointEffective
        ) ?? .unavailable
        let configuration = resolvedEffective?.requestedConfiguration
        let requested = configuration?.activePreference
        let selectedIDs: Set<String> = if appliedAuthorityRevoked {
            []
        } else if configuration?.selectedManagedRelayIDs.isEmpty == false {
            configuration?.selectedManagedRelayIDs ?? []
        } else {
            Set(diagnostics?.selectedRelayIDs ?? [])
        }
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
        return CmxIrohSettingsSnapshot(
            runtimeStatus: Self.settingsRuntimeStatus(
                runtimeState,
                failure: appliedAuthorityRevoked ? .policyExpired : diagnostics?.failure,
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
            policySource: appliedAuthorityRevoked
                ? .unavailable
                : Self.settingsPolicySource(resolvedEffective),
            policySequence: appliedAuthorityRevoked ? nil : diagnostics?.policySequence,
            policyExpiresAt: appliedAuthorityRevoked ? nil : diagnostics?.policyExpiresAt,
            staleRelayIDs: appliedAuthorityRevoked
                ? []
                : Set(diagnostics?.staleRelayIDs ?? []),
            failureDescription: appliedAuthorityRevoked
                ? CmxIrohRelayPolicyFailure.policyExpired.rawValue
                : diagnostics?.failure?.rawValue,
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

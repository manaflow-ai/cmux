import CMUXMobileCore
import CmuxIrohTransport
import Foundation

@MainActor
extension MobileHostIrohRuntime {
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
        #else
        let debugTransportVerificationMode: CmxIrohTransportVerificationMode? = nil
        #endif
        return CmxIrohSettingsSnapshot(
            runtimeStatus: Self.settingsRuntimeStatus(
                runtimeState,
                failure: diagnostics?.failure,
                selectedPath: selectedPath
            ),
            selectedTransportPath: selectedPath,
            preference: Self.settingsPreference(requested),
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
            failureDescription: diagnostics?.failure?.rawValue,
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

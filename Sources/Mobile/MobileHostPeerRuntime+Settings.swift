import CMUXMobileCore
import CmuxPeerTransport
import CmuxPeerTransportCore
import Foundation

extension MobileHostPeerRuntime {
    var transportVerificationMode: CmxIrohTransportVerificationMode {
        #if DEBUG
        Self.debugTransportVerificationMode(defaults: .standard)
        #else
        CmxIrohPathPreference.stored(in: .standard).transportVerificationMode
        #endif
    }

    #if DEBUG
    /// Resolves DEBUG overrides before the release-safe path preference.
    static func debugTransportVerificationMode(
        defaults: UserDefaults
    ) -> CmxIrohTransportVerificationMode {
        if let rawValue = defaults.string(
            forKey: CmxIrohTransportVerificationMode.debugDefaultsKey
        ), let mode = CmxIrohTransportVerificationMode(rawValue: rawValue) {
            return mode
        }
        if defaults.bool(forKey: debugRelayOnlyDefaultsKey) {
            return .relayOnly
        }
        return CmxIrohPathPreference.stored(in: defaults).transportVerificationMode
    }

    static var isDebugRelayOnlyEnabled: Bool {
        debugTransportVerificationMode(defaults: .standard) == .relayOnly
    }
    #endif
}

/// Settings boundary for the peer transport. Custom relays and custom private
/// paths were fork-only knobs of the previous transport and are deliberately
/// not supported by this runtime; their entrypoints fail with `.unsupported`
/// so the Settings UI keeps compiling and shows nothing to configure.
@MainActor
extension MobileHostPeerRuntime: CmxIrohSettingsControlling {
    func irohSettingsSnapshot() async -> CmxIrohSettingsSnapshot {
        let runtimeStatus: CmxIrohSettingsSnapshot.RuntimeStatus
        if active != nil {
            runtimeStatus = .active
        } else if transitionTask != nil, desiredActive, observedAccountID != nil {
            runtimeStatus = .starting
        } else if lastFailureKind != nil, desiredActive {
            runtimeStatus = .degraded
        } else {
            runtimeStatus = .inactive
        }
        let managedRelays = active?.appliedRelayConfigs.enumerated().map { index, config in
            CmxIrohSettingsSnapshot.ManagedRelay(
                id: "relay-\(index)",
                provider: "managed",
                region: "",
                url: config.url,
                isSelected: true
            )
        } ?? []
        #if DEBUG
        let debugTransportVerificationMode: CmxIrohTransportVerificationMode? =
            transportVerificationMode
        #else
        let debugTransportVerificationMode: CmxIrohTransportVerificationMode? = nil
        #endif
        return CmxIrohSettingsSnapshot(
            runtimeStatus: runtimeStatus,
            selectedTransportPath: .unavailable,
            preference: .automatic,
            pathPreference: CmxIrohPathPreference.stored(in: .standard),
            managedRelays: managedRelays,
            customRelays: [],
            policySource: active?.relayPolicySource ?? .unavailable,
            policySequence: active?.relayPolicySequence,
            policyExpiresAt: active?.relayPolicyExpiresAt,
            staleRelayIDs: [],
            failureDescription: lastFailureKind.map { "failure-\($0.rawValue)" },
            debugTransportVerificationMode: debugTransportVerificationMode
        )
    }

    func irohSettingsUpdates() -> AsyncStream<CmxIrohSettingsSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            irohSettingsContinuations[id] = continuation
            Task { @MainActor [weak self] in
                guard let self else { return }
                continuation.yield(await self.irohSettingsSnapshot())
            }
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.irohSettingsContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    /// Persists the device-local path preference and rebinds the endpoint
    /// once. The rebuild reuses the same account-scoped secret key, so the
    /// EndpointID (and therefore the broker binding identity) never rotates.
    func setIrohPathPreference(_ preference: CmxIrohPathPreference) async throws {
        let hadStoredChange = CmxIrohPathPreference.stored(in: .standard) != preference
        let hadEffectiveChange = transportVerificationMode != preference.transportVerificationMode
        UserDefaults.standard.set(
            preference.rawValue,
            forKey: CmxIrohPathPreference.defaultsKey
        )
        #if DEBUG
        UserDefaults.standard.removeObject(
            forKey: CmxIrohTransportVerificationMode.debugDefaultsKey
        )
        UserDefaults.standard.removeObject(forKey: Self.debugRelayOnlyDefaultsKey)
        #endif
        guard hadStoredChange || hadEffectiveChange else { return }
        publishIrohSettingsUpdate()
        await scheduleReconcile(
            eraseAccountState: false,
            restartActiveRuntime: true
        ).value
    }

    func setIrohRelayPreference(
        _ preference: CmxIrohRelayPreferenceDraft
    ) async throws {
        // Managed-relay selection and custom relays were fork-only knobs;
        // the peer transport always uses the full verified managed fleet.
        guard case .automatic = preference else {
            throw CmxIrohSettingsControlError.unsupported
        }
    }

    func upsertIrohCustomRelay(
        _ relay: CmxIrohCustomRelayDraft,
        deviceSecret: String?
    ) async throws {
        throw CmxIrohSettingsControlError.unsupported
    }

    func removeIrohCustomRelay(id: String) async throws {
        throw CmxIrohSettingsControlError.unsupported
    }

    func testIrohCustomRelay(id: String) async -> CmxIrohRelayTestResult {
        .incomplete
    }

    func runIrohConnectionCheck() async -> CmxIrohConnectionCheckReport {
        await refreshIrohSettings()
        let snapshot = await irohSettingsSnapshot()
        let diagnostics = await irohDiagnosticReport()
        let relayReachability: CmxIrohConnectionCheckReport.RelayReachability
        if transportVerificationMode == .directOnly {
            // Relays are administratively excluded by the transport mode; a
            // failed relay probe here must not send users to corporate IT.
            relayReachability = .notConfigured
        } else if let active, !active.appliedRelayConfigs.isEmpty {
            relayReachability = await endpointManager.homeRelayStatus().isConnected
                ? .reachable
                : .unavailable
        } else {
            relayReachability = .notConfigured
        }
        return CmxIrohConnectionCheckReport(
            role: .macHost,
            snapshot: snapshot,
            diagnostics: diagnostics,
            relayReachability: relayReachability
        )
    }

    func refreshIrohSettings() async {
        publishIrohSettingsUpdate()
    }

    func irohDiagnosticReport() async -> DiagnosticReport {
        await diagnosticLog.snapshot()
    }

    func exportIrohDiagnosticReport() async -> Data {
        await diagnosticLog.export()
    }

    func clearIrohDiagnosticReport() async {
        await diagnosticLog.clear()
        publishIrohSettingsUpdate()
    }

    func publishIrohSettingsUpdate() {
        guard !irohSettingsContinuations.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await self.irohSettingsSnapshot()
            for continuation in self.irohSettingsContinuations.values {
                continuation.yield(snapshot)
            }
        }
    }
}

#if DEBUG
extension MobileHostPeerRuntime: CmxIrohDebugSettingsControlling {
    /// Applies one Debug-only path constraint through the same runtime restart
    /// boundary used by Settings: the endpoint rebinds once with the same
    /// identity key, so no identity rotation occurs.
    func setIrohDebugTransportVerificationMode(
        _ mode: CmxIrohTransportVerificationMode
    ) async {
        guard transportVerificationMode != mode else { return }
        UserDefaults.standard.set(
            mode.rawValue,
            forKey: CmxIrohTransportVerificationMode.debugDefaultsKey
        )
        UserDefaults.standard.removeObject(forKey: Self.debugRelayOnlyDefaultsKey)
        publishIrohSettingsUpdate()
        await scheduleReconcile(
            eraseAccountState: false,
            restartActiveRuntime: true
        ).value
    }
}
#endif

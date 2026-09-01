import CMUXMobileCore
import CmuxIrxTransport
import Foundation

/// Thrown for Settings mutations the irx runtime does not support yet.
/// Keeping this explicit lets the UI show its save-failed state rather than
/// implying that a relay preference was persisted when irx owns the fleet.
struct MobileHostIrxSettingsUnsupportedError: LocalizedError {
    var errorDescription: String? {
        String(
            localized: "settings.networking.irx.notConfigurable",
            defaultValue: "This setting is not configurable with the current transport."
        )
    }
}

/// Settings and diagnostic projection for the irx-owned host runtime.
///
/// The runtime remains the single lifecycle owner. This extension exposes a
/// credential-free snapshot and an event stream to the Settings package, while
/// unsupported relay mutations fail explicitly instead of pretending to apply.
@MainActor
extension MobileHostIrxRuntime: CmxIrohSettingsControlling {
    func irohSettingsSnapshot() async -> CmxIrohSettingsSnapshot {
        let broker = brokerService
        let endpoint = endpointSupervisor
        let trust = await broker?.cachedTrust()
        let online = await endpoint?.isHealthy() ?? false
        let homeRelay = await endpoint?.homeRelayURL()
        let path = Self.selectedPath(
            state: activationState,
            endpointOnline: online,
            homeRelayURL: homeRelay
        )
        let runtimeStatus: CmxIrohSettingsSnapshot.RuntimeStatus = switch activationState {
        case .inactive:
            .inactive
        case .activating:
            .starting
        case .retrying:
            .retrying
        case .failed:
            .degraded
        case .reauthenticationRequired:
            .degraded
        case .active:
            online ? CmxIrohSettingsSnapshot.RuntimeStatus(activePath: path) : .starting
        }
        return CmxIrohSettingsSnapshot(
            runtimeStatus: runtimeStatus,
            selectedTransportPath: path,
            preference: .automatic,
            pathPreference: Self.forceRelayOnly ? .relayOnly : .automatic,
            managedRelays: Self.managedRelays(
                trust?.relayFleet ?? [], homeRelayURL: homeRelay
            ),
            customRelays: [],
            policySource: trust == nil
                ? .unavailable
                : (hadLiveDiscovery ? .server : .cached),
            // irx has no separately signed relay-policy lease; relay JWT
            // expiry is owned by the credential autopilot and must not be
            // presented as a policy-expiration timestamp in Settings.
            policyExpiresAt: nil,
            failureDescription: activationState == .failed
                || activationState == .retrying
                || activationState == .reauthenticationRequired
                ? lastBrokerFailure?.diagnosticErrorCode
                : nil,
            requiresReauthentication: activationState == .reauthenticationRequired,
            supportsRelayConfiguration: false,
            debugTransportVerificationMode: nil
        )
    }

    func irohSettingsUpdates() -> AsyncStream<CmxIrohSettingsSnapshot> {
        AsyncStream { continuation in
            let (signals, signalContinuation) = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            let observer = MobileHostStatusObserverToken(
                NotificationCenter.default.addObserver(
                    forName: .mobileHostStatusDidChange,
                    object: nil,
                    queue: nil
                ) { _ in
                    signalContinuation.yield(())
                }
            )
            let task = Task { @MainActor [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                continuation.yield(await self.irohSettingsSnapshot())
                for await _ in signals {
                    guard !Task.isCancelled else { return }
                    continuation.yield(await self.irohSettingsSnapshot())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                signalContinuation.finish()
                observer.remove()
            }
        }
    }

    func setIrohRelayPreference(_ preference: CmxIrohRelayPreferenceDraft) async throws {
        guard case .automatic = preference else {
            throw MobileHostIrxSettingsUnsupportedError()
        }
    }

    func setIrohPathPreference(_ preference: CmxIrohPathPreference) async throws {
        let expected: CmxIrohPathPreference = Self.forceRelayOnly ? .relayOnly : .automatic
        guard preference == expected else {
            throw MobileHostIrxSettingsUnsupportedError()
        }
    }

    func upsertIrohCustomRelay(
        _ relay: CmxIrohCustomRelayDraft,
        deviceSecret: String?
    ) async throws {
        throw MobileHostIrxSettingsUnsupportedError()
    }

    func removeIrohCustomRelay(id: String) async throws {
        throw MobileHostIrxSettingsUnsupportedError()
    }

    func testIrohCustomRelay(id: String) async -> CmxIrohRelayTestResult {
        .incomplete
    }

    func upsertIrohCustomPrivatePath(_ path: CmxIrohCustomPrivatePathDraft) async throws {
        throw MobileHostIrxSettingsUnsupportedError()
    }

    func removeIrohCustomPrivatePath(
        macDeviceID: String,
        instanceTag: String?
    ) async throws {
        throw MobileHostIrxSettingsUnsupportedError()
    }

    func resetIrohSettingsToDefaults() async throws {
        // irx intentionally has no user-editable relay configuration. In
        // forced relay-only mode the preference is managed by the launch
        // policy, so claiming a successful reset would leave the UI and the
        // persisted/runtime state unchanged.
        throw MobileHostIrxSettingsUnsupportedError()
    }

    func refreshIrohSettings() async {
        await refreshIrohSettings(allowActivationRestart: true)
    }

    private func refreshIrohSettings(allowActivationRestart: Bool) async {
        // A connection report is a read-only observation. Preserve every
        // terminal/retrying phase while it is being assembled so the report
        // cannot discard the bounded retry ladder or replace a
        // reauthentication failure with an intermediate .activating snapshot.
        // The public Settings refresh explicitly opts into a new activation
        // attempt.
        if !allowActivationRestart,
           (activationState == .failed
               || activationState == .retrying
               || activationState == .reauthenticationRequired) {
            publishIrxSettingsUpdate()
            return
        }
        if (activationState == .failed
            || activationState == .retrying
            || activationState == .reauthenticationRequired),
           let accountID = activeAccountID {
            cancelActivationRetry()
            cancelAutopilotRecovery()
            activationRetryFailureCount = 0
            activationUnauthorizedFailureCount = 0
            activationMissingAuthenticationFailureCount = 0
            terminalRecoveryCount = 0
            setActivationState(.activating)
            Self.journal.record("host-runtime", "activation-retry-requested")
            startActivation(accountID: accountID)
            return
        }
        if activationState == .active, let autopilot {
            await autopilot.kick()
        }
        guard let broker = brokerService else {
            hadLiveDiscovery = false
            publishIrxSettingsUpdate()
            return
        }
        let token = generationToken
        let accountID = activeAccountID
        do {
            _ = try await broker.discover(maximumAge: 0)
            guard generationToken == token,
                  activeAccountID == accountID,
                  brokerService === broker else { return }
            // Only a discovery completed by this runtime generation may label
            // the retained trust snapshot as server-confirmed.
            hadLiveDiscovery = true
        } catch is CancellationError {
            return
        } catch let failure as IrxBrokerFailure {
            guard generationToken == token,
                  activeAccountID == accountID,
                  brokerService === broker else { return }
            // The disk snapshot remains usable for diagnostics, but it is no
            // longer a server-confirmed snapshot after a failed refresh.
            hadLiveDiscovery = false
            if failure.requiresReauthentication, let accountID {
                await handleActivationFailure(
                    failure,
                    accountID: accountID,
                    token: token
                )
                return
            }
        } catch {
            guard generationToken == token,
                  activeAccountID == accountID,
                  brokerService === broker else { return }
            hadLiveDiscovery = false
        }
        publishIrxSettingsUpdate()
    }

    func runIrohConnectionCheck() async -> CmxIrohConnectionCheckReport {
        await refreshIrohSettings(allowActivationRestart: false)
        let snapshot = await irohSettingsSnapshot()
        let diagnostics = await irohDiagnosticReport()
        let reachable = await endpointSupervisor?.isHealthy() ?? false
        return CmxIrohConnectionCheckReport(
            role: .macHost,
            snapshot: snapshot,
            diagnostics: diagnostics,
            relayReachability: reachable ? .reachable : .unavailable
        )
    }

    func irohDiagnosticReport() async -> DiagnosticReport {
        await MobileHostIrohRuntime.hostDiagnosticLog.snapshot()
    }

    func exportIrohDiagnosticReport() async -> Data {
        await MobileHostIrohRuntime.hostDiagnosticLog.export()
    }

    func clearIrohDiagnosticReport() async {
        await MobileHostIrohRuntime.hostDiagnosticLog.clear()
        publishIrxSettingsUpdate()
    }

    func publishIrxSettingsUpdate() {
        NotificationCenter.default.post(name: .mobileHostStatusDidChange, object: nil)
    }

    private nonisolated static func selectedPath(
        state: IrxHostActivationState,
        endpointOnline: Bool,
        homeRelayURL: String?
    ) -> CmxIrohSelectedTransportPath {
        guard state == .active, endpointOnline, let homeRelayURL,
              let labels = relayLabels(for: homeRelayURL) else {
            return .unavailable
        }
        return .managedRelay(provider: labels.provider, region: labels.region)
    }

    private nonisolated static func managedRelays(
        _ urls: [String],
        homeRelayURL: String?
    ) -> [CmxIrohSettingsSnapshot.ManagedRelay] {
        let home = relayHost(homeRelayURL ?? "")
        var seen = Set<String>()
        return urls.compactMap { url in
            guard let host = relayHost(url), seen.insert(host).inserted,
                  let labels = relayLabels(for: url) else { return nil }
            return CmxIrohSettingsSnapshot.ManagedRelay(
                id: host,
                provider: labels.provider,
                region: labels.region,
                url: url,
                isSelected: host == home
            )
        }
    }

    nonisolated static func relayLabels(
        for url: String
    ) -> (provider: String, region: String)? {
        guard let host = relayHost(url) else { return nil }
        let labels = host.split(separator: ".")
        guard let region = labels.first else { return nil }
        return (
            provider: labels.dropFirst().joined(separator: "."),
            region: String(region).uppercased()
        )
    }

    nonisolated static func relayHost(_ url: String) -> String? {
        guard let host = URLComponents(string: url)?.host, !host.isEmpty else {
            return nil
        }
        let withoutDot = host.hasSuffix(".") ? String(host.dropLast()) : host
        return withoutDot.lowercased()
    }

}

// MARK: - Pure projection

extension MobileHostIrxRuntime {
    /// Projects the lifecycle phase into the settings-facing status without
    /// consulting mutable runtime objects. Keeping this pure makes the status
    /// mapping deterministic for both the app and its package tests.
    nonisolated static func settingsRuntimeStatus(
        phase: SettingsPhase,
        endpointOnline: Bool,
        selectedPath: CmxIrohSelectedTransportPath
    ) -> CmxIrohSettingsSnapshot.RuntimeStatus {
        switch phase {
        case .idle:
            .inactive
        case .activating:
            .starting
        case .failed:
            .degraded
        case .active:
            guard endpointOnline else { return .starting }
            CmxIrohSettingsSnapshot.RuntimeStatus(activePath: selectedPath)
        }
    }

    /// Resolves the redacted path shown by Settings for the irx endpoint.
    nonisolated static func settingsSelectedPath(
        phase: SettingsPhase,
        endpointOnline: Bool,
        homeRelayURL: String?
    ) -> CmxIrohSelectedTransportPath {
        guard phase == .active, endpointOnline, let homeRelayURL,
              let labels = relayLabels(for: homeRelayURL) else {
            return .unavailable
        }
        return .managedRelay(provider: labels.provider, region: labels.region)
    }

    /// Converts the signed relay fleet into stable, deduplicated Settings rows.
    nonisolated static func settingsManagedRelays(
        relayFleet: [String],
        homeRelayURL: String?
    ) -> [CmxIrohSettingsSnapshot.ManagedRelay] {
        managedRelays(relayFleet, homeRelayURL: homeRelayURL)
    }

    /// Pure snapshot projection used by the macOS settings mapping tests.
    /// `failureDescription` and `requiresReauthentication` are optional so
    /// callers that only model ordinary lifecycle phases retain the compact
    /// original API.
    nonisolated static func settingsSnapshot(
        phase: SettingsPhase,
        forceRelayOnly: Bool,
        endpointOnline: Bool,
        homeRelayURL: String?,
        relayFleet: [String],
        hasTrustSnapshot: Bool,
        hadLiveDiscovery: Bool,
        credentialExpiry: Date?,
        failureDescription: String? = nil,
        requiresReauthentication: Bool = false
    ) -> CmxIrohSettingsSnapshot {
        let selectedPath = settingsSelectedPath(
            phase: phase,
            endpointOnline: endpointOnline,
            homeRelayURL: homeRelayURL
        )
        #if DEBUG
        let debugMode: CmxIrohTransportVerificationMode? =
            forceRelayOnly ? .relayOnly : .automatic
        #else
        let debugMode: CmxIrohTransportVerificationMode? = nil
        #endif
        return CmxIrohSettingsSnapshot(
            runtimeStatus: requiresReauthentication
                ? .degraded
                : settingsRuntimeStatus(
                    phase: phase,
                    endpointOnline: endpointOnline,
                    selectedPath: selectedPath
                ),
            selectedTransportPath: selectedPath,
            preference: .automatic,
            pathPreference: forceRelayOnly ? .relayOnly : .automatic,
            managedRelays: settingsManagedRelays(
                relayFleet: relayFleet,
                homeRelayURL: homeRelayURL
            ),
            customRelays: [],
            policySource: hasTrustSnapshot
                ? (hadLiveDiscovery ? .server : .cached)
                : .unavailable,
            policyExpiresAt: credentialExpiry,
            failureDescription: failureDescription
                ?? (phase == .failed ? "irx-activation-failed" : nil),
            requiresReauthentication: requiresReauthentication,
            supportsRelayConfiguration: false,
            debugTransportVerificationMode: debugMode
        )
    }
}

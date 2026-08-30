import CMUXMobileCore
import CmuxIrxTransport
import Foundation

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
        let credentials = await broker?.cachedRelayCredentials() ?? []
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
        case .activating, .retrying:
            .starting
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
            policyExpiresAt: credentials.map(\.expiresAt).max(),
            failureDescription: activationState == .failed
                || activationState == .reauthenticationRequired
                ? lastBrokerFailure?.errorCode
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
            throw CmxIrohSettingsControlError.unsupported
        }
    }

    func setIrohPathPreference(_ preference: CmxIrohPathPreference) async throws {
        let expected: CmxIrohPathPreference = Self.forceRelayOnly ? .relayOnly : .automatic
        guard preference == expected else {
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

    func upsertIrohCustomPrivatePath(_ path: CmxIrohCustomPrivatePathDraft) async throws {
        throw CmxIrohSettingsControlError.unsupported
    }

    func removeIrohCustomPrivatePath(
        macDeviceID: String,
        instanceTag: String?
    ) async throws {
        throw CmxIrohSettingsControlError.unsupported
    }

    func resetIrohSettingsToDefaults() async throws {}

    func refreshIrohSettings() async {
        guard let broker = brokerService else {
            publishIrxSettingsUpdate()
            return
        }
        hadLiveDiscovery = (try? await broker.discover(maximumAge: 0)) != nil
        publishIrxSettingsUpdate()
    }

    func runIrohConnectionCheck() async -> CmxIrohConnectionCheckReport {
        await refreshIrohSettings()
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

    private nonisolated static func relayLabels(
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

    private nonisolated static func relayHost(_ url: String) -> String? {
        guard let host = URLComponents(string: url)?.host, !host.isEmpty else {
            return nil
        }
        let withoutDot = host.hasSuffix(".") ? String(host.dropLast()) : host
        return withoutDot.lowercased()
    }
}

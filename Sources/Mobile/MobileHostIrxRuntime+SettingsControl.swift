import CMUXMobileCore
import Foundation

/// Thrown for Settings mutations the irx runtime does not support yet
/// (managed/custom relay selection, custom relay definitions, path
/// preferences beyond the force-relay debug flag). Explicit so the UI shows
/// its save-failed alert instead of pretending the change persisted.
struct MobileHostIrxSettingsUnsupportedError: LocalizedError {
    var errorDescription: String? {
        String(
            localized: "settings.networking.irx.notConfigurable",
            defaultValue: "This setting is not configurable with the current transport."
        )
    }
}

/// Settings Networking backend for the irx runtime. Read paths project the
/// real irx state (activation phase, endpoint relay link, cached broker
/// trust/credentials); mutations irx cannot honor throw
/// ``MobileHostIrxSettingsUnsupportedError`` rather than no-op.
@MainActor
extension MobileHostIrxRuntime: CmxIrohSettingsControlling {
    func irohSettingsSnapshot() async -> CmxIrohSettingsSnapshot {
        let phase = settingsPhase
        let hadLiveDiscovery = hadLiveDiscoveryThisRun
        let broker = brokerService
        let supervisor = endpointSupervisor
        let trust = await broker?.cachedTrust()
        let credentials = await broker?.cachedRelayCredentials() ?? []
        let endpointOnline = await supervisor?.isHealthy() ?? false
        let homeRelayURL = await supervisor?.homeRelayURL()
        return Self.settingsSnapshot(
            phase: phase,
            forceRelayOnly: Self.forceRelayOnly,
            endpointOnline: endpointOnline,
            homeRelayURL: homeRelayURL,
            relayFleet: trust?.relayFleet ?? [],
            hasTrustSnapshot: trust != nil,
            hadLiveDiscovery: hadLiveDiscovery,
            credentialExpiry: credentials.map(\.expiresAt).max()
        )
    }

    func irohSettingsUpdates() -> AsyncStream<CmxIrohSettingsSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            irxSettingsContinuations[id] = continuation
            ensureSettingsRefreshLoop()
            Task { @MainActor [weak self] in
                guard let self else { return }
                continuation.yield(await self.irohSettingsSnapshot())
            }
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.irxSettingsContinuations.removeValue(forKey: id)
                    if self.irxSettingsContinuations.isEmpty {
                        self.irxSettingsRefreshTask?.cancel()
                        self.irxSettingsRefreshTask = nil
                    }
                }
            }
        }
    }

    func setIrohRelayPreference(_ preference: CmxIrohRelayPreferenceDraft) async throws {
        // irx has no account relay preference: the usable relay set IS the
        // signed server fleet. Automatic therefore already holds (idempotent
        // success); any narrowing is unsupported and must fail loudly.
        guard case .automatic = preference else {
            throw MobileHostIrxSettingsUnsupportedError()
        }
    }

    func setIrohPathPreference(_ preference: CmxIrohPathPreference) async throws {
        // The force-relay debug flag is fixed at activation; only requests
        // that already match the active mode succeed (idempotent set).
        switch preference {
        case .automatic where !Self.forceRelayOnly:
            return
        case .relayOnly where Self.forceRelayOnly:
            return
        default:
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
        // No custom relays exist under irx, so no definition is testable.
        .incomplete
    }

    func resetIrohSettingsToDefaults() async throws {
        // irx persists no user-configurable networking state; defaults are
        // already in effect, so reset genuinely leaves the requested state.
    }

    func refreshIrohSettings() async {
        guard let broker = brokerService else {
            publishIrxSettingsUpdate()
            return
        }
        // Force a live discovery so the fleet and policy source are current.
        if (try? await broker.discover(maximumAge: 0)) != nil {
            noteLiveDiscoverySucceeded()
        }
        publishIrxSettingsUpdate()
    }

    func runIrohConnectionCheck() async -> CmxIrohConnectionCheckReport {
        await refreshIrohSettings()
        let snapshot = await irohSettingsSnapshot()
        let diagnostics = await irohDiagnosticReport()
        let endpointOnline = await endpointSupervisor?.isHealthy() ?? false
        let relayReachability: CmxIrohConnectionCheckReport.RelayReachability
        if settingsPhase == .idle {
            relayReachability = .notConfigured
        } else if endpointOnline {
            // The endpoint's relay link is up; irx readiness IS relay
            // reachability (v1 serves relay paths only).
            relayReachability = .reachable
        } else {
            // Indeterminate (activating, rebinding, or failed): never send
            // users to corporate IT off a probe that did not run.
            relayReachability = .unavailable
        }
        return CmxIrohConnectionCheckReport(
            role: .macHost,
            snapshot: snapshot,
            diagnostics: diagnostics,
            relayReachability: relayReachability
        )
    }

    /// Pushes a fresh snapshot to every live Settings subscriber. Cheap when
    /// nobody is subscribed.
    func publishIrxSettingsUpdate() {
        guard !irxSettingsContinuations.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await self.irohSettingsSnapshot()
            for continuation in self.irxSettingsContinuations.values {
                continuation.yield(snapshot)
            }
        }
    }

    /// Periodic re-yield while (and only while) subscribers exist, so
    /// credential-expiry drift and missed hooks self-heal without tight
    /// timers. Cancelled by the last subscriber's termination.
    private func ensureSettingsRefreshLoop() {
        guard irxSettingsRefreshTask == nil else { return }
        irxSettingsRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                guard !self.irxSettingsContinuations.isEmpty else {
                    self.irxSettingsRefreshTask = nil
                    return
                }
                self.publishIrxSettingsUpdate()
            }
        }
    }
}

// MARK: - Pure projection (unit-tested in MobileHostIrxSettingsMappingTests)

extension MobileHostIrxRuntime {
    nonisolated static func settingsSnapshot(
        phase: SettingsPhase,
        forceRelayOnly: Bool,
        endpointOnline: Bool,
        homeRelayURL: String?,
        relayFleet: [String],
        hasTrustSnapshot: Bool,
        hadLiveDiscovery: Bool,
        credentialExpiry: Date?
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
            runtimeStatus: settingsRuntimeStatus(
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
            policySequence: nil,
            // The relay credentials' signed expiry is the truthful "policy"
            // lifetime in irx: past it the endpoint loses relay authority
            // until the autopilot mints again.
            policyExpiresAt: credentialExpiry,
            staleRelayIDs: [],
            failureDescription: phase == .failed ? "irx-activation-failed" : nil,
            debugTransportVerificationMode: debugMode
        )
    }

    nonisolated static func settingsRuntimeStatus(
        phase: SettingsPhase,
        endpointOnline: Bool,
        selectedPath: CmxIrohSelectedTransportPath
    ) -> CmxIrohSettingsSnapshot.RuntimeStatus {
        switch phase {
        case .idle:
            return .inactive
        case .activating:
            return .starting
        case .failed:
            return .degraded
        case .active:
            // An active runtime whose endpoint dropped is rebinding (the
            // accept loop re-establishes it), not persistently failed.
            guard endpointOnline else { return .starting }
            return CmxIrohSettingsSnapshot.RuntimeStatus(activePath: selectedPath)
        }
    }

    /// Relay for now: direct paths are unwired in irx v1, so the only
    /// attributable live path is the relay the endpoint homes on.
    nonisolated static func settingsSelectedPath(
        phase: SettingsPhase,
        endpointOnline: Bool,
        homeRelayURL: String?
    ) -> CmxIrohSelectedTransportPath {
        guard phase == .active, endpointOnline, let homeRelayURL,
            let labels = relayLabels(for: homeRelayURL)
        else { return .unavailable }
        return .managedRelay(provider: labels.provider, region: labels.region)
    }

    nonisolated static func settingsManagedRelays(
        relayFleet: [String],
        homeRelayURL: String?
    ) -> [CmxIrohSettingsSnapshot.ManagedRelay] {
        let homeHost = homeRelayURL.flatMap(relayHost)
        var seenHosts = Set<String>()
        return relayFleet.compactMap { url in
            guard let host = relayHost(url), seenHosts.insert(host).inserted,
                let labels = relayLabels(for: url)
            else { return nil }
            return CmxIrohSettingsSnapshot.ManagedRelay(
                id: host,
                provider: labels.provider,
                region: labels.region,
                url: url,
                isSelected: host == homeHost
            )
        }
    }

    /// Data-derived display labels for a relay URL: region is the host's
    /// first DNS label (the fleet's region prefix, e.g. `use4`), provider is
    /// the remaining host. No signed catalog exists in irx to source labels.
    nonisolated static func relayLabels(
        for url: String
    ) -> (provider: String, region: String)? {
        guard let host = relayHost(url) else { return nil }
        let labels = host.split(separator: ".")
        guard let first = labels.first else { return nil }
        guard labels.count > 1 else { return (provider: host, region: host) }
        return (
            provider: labels.dropFirst().joined(separator: "."),
            region: String(first).uppercased()
        )
    }

    /// Canonical relay host: lowercased, FQDN trailing dot stripped (the
    /// iroh driver reports its home relay with one), used for identity and
    /// selected-relay matching.
    nonisolated static func relayHost(_ url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URLComponents(string: trimmed)?.host, !host.isEmpty
        else { return nil }
        let canonical = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard !canonical.isEmpty else { return nil }
        return canonical.lowercased()
    }
}

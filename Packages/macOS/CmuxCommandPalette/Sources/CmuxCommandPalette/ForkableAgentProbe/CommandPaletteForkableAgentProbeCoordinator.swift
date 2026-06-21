public import Foundation
public import Observation

/// `@MainActor @Observable` coordinator that owns the command palette's
/// forkable-agent availability cache and drives the per-panel capability probe.
///
/// The command palette shows a "fork conversation" command only for terminal
/// panels whose backing agent session can be forked. Deciding that is partly
/// synchronous (the snapshot's declared fork command and agent kind) and partly
/// asynchronous (an OpenCode version probe, a live restorable-session index
/// load). This coordinator owns all of that bookkeeping: the per-panel support
/// set, resolved snapshots, snapshot fingerprints, remote-context flags, the
/// "result had fallback" flags, and the generation-guarded in-flight probe
/// tasks. The host (`ContentView`) holds one coordinator and routes every
/// forkable-agent read and write through it.
///
/// ## Isolation
///
/// Every mutator and reader of this state runs on the main actor (SwiftUI body
/// reads, keyboard/command dispatch, and the main-actor tail of each probe
/// task), so the coordinator is `@MainActor`. The probe itself is `async` and
/// performs no UI work; it hands its decision back through a
/// ``CommandPaletteForkableAgentProbeHost`` passed in per call. Cancellation is
/// generation-based (a per-panel probe id and a probe fingerprint) rather than
/// retained `DispatchWorkItem`s: a stale completion checks both guards and
/// no-ops.
///
/// ## Host injection
///
/// The host is a value-typed SwiftUI `View` that is reconstructed every render,
/// so the coordinator never stores it. Each driving method takes the current
/// host, exactly mirroring how the palette's switcher builder receives a fresh
/// `snapshotProvider: self`. The async probe captures the host passed in, the
/// same way the legacy in-host `Task` captured `self`.
///
/// ## Faithful lift
///
/// The cache state machine, fingerprint inputs, reuse/clear decisions, and the
/// probe lifecycle reproduce the legacy in-host code byte-for-byte. Everything
/// that needs the host's concrete snapshot type stays behind the host seam.
@MainActor
@Observable
public final class CommandPaletteForkableAgentProbeCoordinator<Host: CommandPaletteForkableAgentProbeHost> {
    /// The host's restorable agent-snapshot value type.
    public typealias Snapshot = Host.Snapshot

    /// The panel key whose forkable-agent availability is currently being
    /// tracked, or `nil` when the active scope has no eligible terminal panel.
    @ObservationIgnored public var activePanelKey: String?

    @ObservationIgnored private var probeIDsByPanelKey: [String: UUID] = [:]

    /// Panel keys whose backing agent session is known to support forking.
    @ObservationIgnored public var supportedPanelKeys: Set<String> = []

    /// The resolved fork snapshot cached per panel key.
    @ObservationIgnored public var snapshotsByPanelKey: [String: Snapshot] = [:]

    /// The cached snapshot fingerprint per panel key.
    @ObservationIgnored public var snapshotFingerprintsByPanelKey: [String: String] = [:]

    /// Whether the cached result for a panel key was probed in a remote context.
    @ObservationIgnored public var remoteContextsByPanelKey: [String: Bool] = [:]

    /// Whether a cached result was derived from a fallback snapshot (no live
    /// index snapshot), which forces a re-probe on the next refresh.
    @ObservationIgnored public var resultHadFallbackByPanelKey: [String: Bool] = [:]

    @ObservationIgnored private var availabilityTasksByPanelKey: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var probeFingerprintsByPanelKey: [String: String] = [:]

    /// Creates an empty coordinator.
    public init() {}

    // MARK: - Pure helpers

    /// Stable per-panel cache key from a workspace id and panel id.
    public static func panelKey(workspaceId: UUID, panelId: UUID) -> String {
        "\(workspaceId.uuidString):\(panelId.uuidString)"
    }

    /// The cache fingerprint for a resolved snapshot, preferring a provided
    /// fallback fingerprint, otherwise the host-derived snapshot fingerprint.
    public func forkCacheFingerprint(
        host: Host,
        snapshot: Snapshot,
        fallbackFingerprint: String?
    ) -> String {
        fallbackFingerprint ?? host.commandPaletteForkSnapshotFingerprint(snapshot)
    }

    /// Whether a cached probe result matches the expected panel context.
    public static func probeResultMatches(
        panelKey: String,
        supportedPanelKeys: Set<String>,
        supportedRemoteContextsByPanelKey: [String: Bool],
        snapshotFingerprintsByPanelKey: [String: String],
        expectedSnapshotFingerprint: String?,
        isRemoteTerminal: Bool
    ) -> Bool {
        guard supportedPanelKeys.contains(panelKey),
              supportedRemoteContextsByPanelKey[panelKey] == isRemoteTerminal else {
            return false
        }
        guard let expectedSnapshotFingerprint else {
            return true
        }
        return snapshotFingerprintsByPanelKey[panelKey] == expectedSnapshotFingerprint
    }

    /// Whether a cached probe result can be reused without re-probing.
    public static func shouldReuseProbeResult(
        panelKey: String,
        supportedPanelKeys: Set<String>,
        supportedRemoteContextsByPanelKey: [String: Bool],
        snapshotFingerprintsByPanelKey: [String: String],
        expectedSnapshotFingerprint: String?,
        isRemoteTerminal: Bool,
        cachedResultHadFallback: Bool,
        panelChanged: Bool
    ) -> Bool {
        !panelChanged && !cachedResultHadFallback && probeResultMatches(
            panelKey: panelKey,
            supportedPanelKeys: supportedPanelKeys,
            supportedRemoteContextsByPanelKey: supportedRemoteContextsByPanelKey,
            snapshotFingerprintsByPanelKey: snapshotFingerprintsByPanelKey,
            expectedSnapshotFingerprint: expectedSnapshotFingerprint,
            isRemoteTerminal: isRemoteTerminal
        )
    }

    /// Whether the cached probe result must be cleared before re-probing.
    public static func shouldClearProbeResultBeforeProbe(
        panelKey: String,
        supportedPanelKeys: Set<String>,
        supportedRemoteContextsByPanelKey: [String: Bool],
        snapshotFingerprintsByPanelKey: [String: String],
        expectedSnapshotFingerprint: String?,
        isRemoteTerminal: Bool,
        cachedResultHadFallback: Bool,
        panelChanged: Bool
    ) -> Bool {
        panelChanged || cachedResultHadFallback || !probeResultMatches(
            panelKey: panelKey,
            supportedPanelKeys: supportedPanelKeys,
            supportedRemoteContextsByPanelKey: supportedRemoteContextsByPanelKey,
            snapshotFingerprintsByPanelKey: snapshotFingerprintsByPanelKey,
            expectedSnapshotFingerprint: expectedSnapshotFingerprint,
            isRemoteTerminal: isRemoteTerminal
        )
    }

    /// The "result had fallback" flag to record when a matched fallback result
    /// is reused; defaults to `true` when no prior flag exists.
    public static func matchedFallbackProbeResultHadFallback(
        cachedResultHadFallback: Bool?
    ) -> Bool {
        cachedResultHadFallback ?? true
    }

    // MARK: - Refresh

    /// Recomputes the active panel's forkable-agent availability.
    ///
    /// `panelContext`, when present, carries the focused terminal panel's
    /// workspace id, panel id, remote-context flag, and fallback snapshot. When
    /// `scopeIsCommands` is `false` or there is no focused terminal panel, the
    /// active panel is cleared and all probes are cancelled.
    public func refreshAvailabilityIfNeeded(
        host: Host,
        scopeIsCommands: Bool,
        panelContext: CommandPaletteForkableAgentPanelContext<Snapshot>?
    ) {
        guard scopeIsCommands, let panelContext else {
            activePanelKey = nil
            cancelAllProbes()
            return
        }

        let workspaceId = panelContext.workspaceId
        let panelId = panelContext.panelId
        let isRemoteTerminal = panelContext.isRemoteTerminal
        let panelKey = Self.panelKey(workspaceId: workspaceId, panelId: panelId)
        let panelChanged = activePanelKey != panelKey
        activePanelKey = panelKey
        let fallbackSnapshot = panelContext.fallbackSnapshot

        if let fallbackSnapshot {
            let fallbackFingerprint = host.commandPaletteForkSnapshotFingerprint(fallbackSnapshot)
            if let cachedFingerprint = snapshotFingerprintsByPanelKey[panelKey],
               cachedFingerprint != fallbackFingerprint {
                cancelProbe(for: panelKey)
                supportedPanelKeys.remove(panelKey)
                snapshotsByPanelKey.removeValue(forKey: panelKey)
                snapshotFingerprintsByPanelKey.removeValue(forKey: panelKey)
                remoteContextsByPanelKey.removeValue(forKey: panelKey)
                resultHadFallbackByPanelKey.removeValue(forKey: panelKey)
            }
            switch host.commandPaletteSnapshotForkAvailability(
                fallbackSnapshot,
                isRemoteTerminal: isRemoteTerminal
            ) {
            case .supportedWithoutProbe:
                let probeResultMatches = Self.probeResultMatches(
                    panelKey: panelKey,
                    supportedPanelKeys: supportedPanelKeys,
                    supportedRemoteContextsByPanelKey: remoteContextsByPanelKey,
                    snapshotFingerprintsByPanelKey: snapshotFingerprintsByPanelKey,
                    expectedSnapshotFingerprint: fallbackFingerprint,
                    isRemoteTerminal: isRemoteTerminal
                )
                if probeResultMatches {
                    supportedPanelKeys.insert(panelKey)
                    remoteContextsByPanelKey[panelKey] = isRemoteTerminal
                    resultHadFallbackByPanelKey[panelKey] =
                        Self.matchedFallbackProbeResultHadFallback(
                            cachedResultHadFallback: resultHadFallbackByPanelKey[panelKey]
                        )
                } else {
                    supportedPanelKeys.remove(panelKey)
                    snapshotsByPanelKey.removeValue(forKey: panelKey)
                    snapshotFingerprintsByPanelKey.removeValue(forKey: panelKey)
                    remoteContextsByPanelKey.removeValue(forKey: panelKey)
                    resultHadFallbackByPanelKey.removeValue(forKey: panelKey)
                }
                if panelChanged || !probeResultMatches {
                    startAvailabilityProbe(
                        host: host,
                        panelKey: panelKey,
                        workspaceId: workspaceId,
                        panelId: panelId,
                        fallbackSnapshot: fallbackSnapshot,
                        fallbackFingerprint: fallbackFingerprint,
                        isRemoteTerminal: isRemoteTerminal
                    )
                }
                return
            case .unsupported:
                cancelProbe(for: panelKey)
                supportedPanelKeys.remove(panelKey)
                snapshotsByPanelKey.removeValue(forKey: panelKey)
                snapshotFingerprintsByPanelKey.removeValue(forKey: panelKey)
                remoteContextsByPanelKey.removeValue(forKey: panelKey)
                resultHadFallbackByPanelKey.removeValue(forKey: panelKey)
                return
            case .requiresProbe:
                let probeResultMatches = Self.probeResultMatches(
                    panelKey: panelKey,
                    supportedPanelKeys: supportedPanelKeys,
                    supportedRemoteContextsByPanelKey: remoteContextsByPanelKey,
                    snapshotFingerprintsByPanelKey: snapshotFingerprintsByPanelKey,
                    expectedSnapshotFingerprint: fallbackFingerprint,
                    isRemoteTerminal: isRemoteTerminal
                )
                if probeResultMatches {
                    resultHadFallbackByPanelKey[panelKey] =
                        Self.matchedFallbackProbeResultHadFallback(
                            cachedResultHadFallback: resultHadFallbackByPanelKey[panelKey]
                        )
                }
                if probeResultMatches && !panelChanged {
                    return
                }
                if !probeResultMatches {
                    supportedPanelKeys.remove(panelKey)
                    snapshotsByPanelKey.removeValue(forKey: panelKey)
                    snapshotFingerprintsByPanelKey.removeValue(forKey: panelKey)
                    remoteContextsByPanelKey.removeValue(forKey: panelKey)
                    resultHadFallbackByPanelKey.removeValue(forKey: panelKey)
                }
                startAvailabilityProbe(
                    host: host,
                    panelKey: panelKey,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    fallbackSnapshot: fallbackSnapshot,
                    fallbackFingerprint: fallbackFingerprint,
                    isRemoteTerminal: isRemoteTerminal
                )
                return
            }
        }

        let cachedResultHadFallback = resultHadFallbackByPanelKey[panelKey] == true
        if Self.shouldReuseProbeResult(
            panelKey: panelKey,
            supportedPanelKeys: supportedPanelKeys,
            supportedRemoteContextsByPanelKey: remoteContextsByPanelKey,
            snapshotFingerprintsByPanelKey: snapshotFingerprintsByPanelKey,
            expectedSnapshotFingerprint: nil,
            isRemoteTerminal: isRemoteTerminal,
            cachedResultHadFallback: cachedResultHadFallback,
            panelChanged: panelChanged
        ) {
            return
        }

        if Self.shouldClearProbeResultBeforeProbe(
            panelKey: panelKey,
            supportedPanelKeys: supportedPanelKeys,
            supportedRemoteContextsByPanelKey: remoteContextsByPanelKey,
            snapshotFingerprintsByPanelKey: snapshotFingerprintsByPanelKey,
            expectedSnapshotFingerprint: nil,
            isRemoteTerminal: isRemoteTerminal,
            cachedResultHadFallback: cachedResultHadFallback,
            panelChanged: panelChanged
        ) {
            supportedPanelKeys.remove(panelKey)
            snapshotsByPanelKey.removeValue(forKey: panelKey)
            snapshotFingerprintsByPanelKey.removeValue(forKey: panelKey)
            remoteContextsByPanelKey.removeValue(forKey: panelKey)
            resultHadFallbackByPanelKey.removeValue(forKey: panelKey)
        }
        startAvailabilityProbe(
            host: host,
            panelKey: panelKey,
            workspaceId: workspaceId,
            panelId: panelId,
            fallbackSnapshot: nil,
            fallbackFingerprint: nil,
            isRemoteTerminal: isRemoteTerminal
        )
    }

    // MARK: - Probe lifecycle

    private func startAvailabilityProbe(
        host: Host,
        panelKey: String,
        workspaceId: UUID,
        panelId: UUID,
        fallbackSnapshot: Snapshot?,
        fallbackFingerprint: String?,
        isRemoteTerminal: Bool
    ) {
        let probeFingerprint = "\(fallbackFingerprint ?? "")\u{1f}\(isRemoteTerminal ? "remote" : "local")"
        if let task = availabilityTasksByPanelKey[panelKey] {
            guard probeFingerprintsByPanelKey[panelKey] != probeFingerprint else { return }
            task.cancel()
            availabilityTasksByPanelKey.removeValue(forKey: panelKey)
            probeIDsByPanelKey.removeValue(forKey: panelKey)
            probeFingerprintsByPanelKey.removeValue(forKey: panelKey)
        }
        let probeID = UUID()
        probeIDsByPanelKey[panelKey] = probeID
        probeFingerprintsByPanelKey[panelKey] = probeFingerprint

        availabilityTasksByPanelKey[panelKey] = Task { [weak self] in
            let result = await host.commandPaletteProbeForkableAgentSupport(
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackSnapshot: fallbackSnapshot,
                isRemoteTerminal: isRemoteTerminal
            )
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                self.applyProbeResult(
                    result,
                    host: host,
                    panelKey: panelKey,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    probeID: probeID,
                    probeFingerprint: probeFingerprint,
                    fallbackFingerprint: fallbackFingerprint,
                    isRemoteTerminal: isRemoteTerminal
                )
            }
        }
    }

    private func applyProbeResult(
        _ result: CommandPaletteForkableAgentProbeResult<Snapshot>,
        host: Host,
        panelKey: String,
        workspaceId: UUID,
        panelId: UUID,
        probeID: UUID,
        probeFingerprint: String,
        fallbackFingerprint: String?,
        isRemoteTerminal: Bool
    ) {
        guard probeIDsByPanelKey[panelKey] == probeID else { return }
        guard probeFingerprintsByPanelKey[panelKey] == probeFingerprint else { return }
        if let fallbackFingerprint,
           let currentFallbackFingerprint = host.commandPaletteCurrentFallbackSnapshotFingerprint(
               workspaceId: workspaceId,
               panelId: panelId
           ),
           currentFallbackFingerprint != fallbackFingerprint {
            probeIDsByPanelKey.removeValue(forKey: panelKey)
            probeFingerprintsByPanelKey.removeValue(forKey: panelKey)
            availabilityTasksByPanelKey.removeValue(forKey: panelKey)
            return
        }
        let wasSupported = supportedPanelKeys.contains(panelKey)
        let hadCachedSnapshot = snapshotsByPanelKey[panelKey] != nil
        let shouldRefreshResults: Bool
        if result.supportsFork {
            shouldRefreshResults = !wasSupported
            supportedPanelKeys.insert(panelKey)
            remoteContextsByPanelKey[panelKey] = isRemoteTerminal
            if let snapshot = result.resolvedSnapshot {
                snapshotsByPanelKey[panelKey] = snapshot
                snapshotFingerprintsByPanelKey[panelKey] = forkCacheFingerprint(
                    host: host,
                    snapshot: snapshot,
                    fallbackFingerprint: fallbackFingerprint
                )
                resultHadFallbackByPanelKey[panelKey] = result.usedFallbackSnapshot
            }
        } else {
            shouldRefreshResults = wasSupported || hadCachedSnapshot
            supportedPanelKeys.remove(panelKey)
            snapshotsByPanelKey.removeValue(forKey: panelKey)
            snapshotFingerprintsByPanelKey.removeValue(forKey: panelKey)
            remoteContextsByPanelKey.removeValue(forKey: panelKey)
            resultHadFallbackByPanelKey.removeValue(forKey: panelKey)
        }
        probeIDsByPanelKey.removeValue(forKey: panelKey)
        probeFingerprintsByPanelKey.removeValue(forKey: panelKey)
        availabilityTasksByPanelKey.removeValue(forKey: panelKey)
        if shouldRefreshResults, activePanelKey == panelKey {
            host.commandPaletteRefreshResultsAfterForkableAgentProbe(activePanelKey: panelKey)
        }
    }

    /// Cancels every in-flight forkable-agent probe and clears probe-generation
    /// bookkeeping. The cached availability results are left intact.
    public func cancelAllProbes() {
        for task in availabilityTasksByPanelKey.values {
            task.cancel()
        }
        availabilityTasksByPanelKey.removeAll()
        probeIDsByPanelKey.removeAll()
        probeFingerprintsByPanelKey.removeAll()
    }

    /// Cancels the in-flight forkable-agent probe for one panel key.
    public func cancelProbe(for panelKey: String) {
        availabilityTasksByPanelKey.removeValue(forKey: panelKey)?.cancel()
        probeIDsByPanelKey.removeValue(forKey: panelKey)
        probeFingerprintsByPanelKey.removeValue(forKey: panelKey)
    }
}

internal import CMUXMobileCore
internal import CmuxMobileDiagnostics
public import CmuxMobilePairedMac
public import CmuxMobileRPC
public import Foundation

/// Observable-gap measurement for one roaming make-before-break swap:
/// stamped at dial start, at the last event the old connection delivered
/// before its terminal registration is drained, and at swap commit; resolved
/// by the first event applied on the replacement connection.
struct RoamingSwapGapProbe: Sendable {
    let dialStartedAt: Date
    var lastEventBeforeSwapAt: Date?
    var swapCommittedAt: Date?
}

/// Make-before-break recovery for the relay (`.websocket`) foreground route.
///
/// A network path change usually breaks the relay WebSocket silently while a
/// fresh dial over the NEW path would succeed immediately. The ordinary
/// recovery first probes the old socket (burning its timeout), then tears the
/// session down, then redials: the user watches a 1–2s+ freeze. The Durable
/// Object accepts multiple concurrent sessions per client, so roaming instead
/// dials the replacement while the old session keeps serving whatever still
/// flows, and swaps through the exact `previousFocusedConnection` handoff the
/// connect() route loop already performs. Arbitration stays with the existing
/// owner machinery: the recovery owner serializes attempts, the connect
/// attempt registry's bounded replacement admission shares the one physical
/// route, and every displaced or failed client leaves through the same
/// retire/disconnect gates as any other connect.
@MainActor
extension MobileShellComposite {
    /// The registry entry for the client currently serving as foreground, or
    /// nil when the registry and the published client disagree. Focused
    /// entries are keyed by (device, STORED instance tag); the bare-id
    /// compatibility subscript resolves a nil-tag key and misses tagged
    /// pairings, so the tagged foreground key is consulted as well.
    var servingFocusedConnection: MacConnection? {
        guard let foregroundMacDeviceID, remoteClient != nil else { return nil }
        let connection = connections[foregroundMacDeviceID]
            ?? connections[foregroundMacKey]
        guard let connection, connection.client === remoteClient else {
            return nil
        }
        return connection
    }

    /// Starts one make-before-break roaming swap when the current foreground
    /// connection is a live relay session. Returns whether the trigger was
    /// consumed (an attempt started, or an already-active owner coalesced it,
    /// exactly as the ordinary recovery entry would).
    func startRoamingRelaySwapIfEligible(trigger: RecoveryTrigger) -> Bool {
        guard connectionState == .connected,
              remoteClient != nil,
              activeRoute?.kind == .websocket,
              pairedMacStore != nil,
              !isReconnectingStoredMac,
              servingFocusedConnection != nil else {
            return false
        }
        guard let attempt = connectionRecoveryOwner.begin(
            trigger: "\(trigger.description).roaming",
            sourceConnectionGeneration: connectionGeneration,
            probing: false
        ) else {
            // An active attempt already owns recovery; this trigger coalesces
            // into it exactly as it does on the ordinary path.
            return true
        }
        roamingSwapAttemptID = attempt.id
        roamingSwapOldClientDied = false
        roamingSwapGapProbe = RoamingSwapGapProbe(
            dialStartedAt: runtime?.now() ?? Date()
        )
        diagnosticLog?.record(DiagnosticEvent(
            .recoveryStarted,
            surface: attempt.diagnosticID,
            a: activeRoute.map { DiagnosticTransportKind($0.kind).rawValue }
                ?? DiagnosticTransportKind.unknown.rawValue,
            b: trigger.diagnosticCode,
            c: activePeerDiagnosticAlias.map(Int.init)
        ))
        applyConnectionRecoveryOwnerState()
        MobileDebugLog.anchormux(
            "roaming.swap start attempt=\(attempt.id.uuidString)"
        )
        let stackUserID = lastReconnectStackUserID ?? identityProvider?.currentUserID

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.connectionRecoveryOwner.clearTask(for: attempt) }
            guard self.connectionRecoveryOwner.isCurrent(attempt) else { return }
            // Same hard ceiling as the shared stored-Mac reconnect entry: a
            // wedged dial degrades into a bounded failure (the old session
            // keeps serving), never an owner that coalesces every later
            // trigger forever.
            let deadlineNanoseconds = self.runtime?.reconnectAttemptDeadlineNanoseconds
                ?? 30_000_000_000
            let race = await Self.raceAgainstDeadline(
                nanoseconds: deadlineNanoseconds
            ) { [weak self] in
                await self?.performRoamingRelaySwapDial(
                    attempt: attempt,
                    stackUserID: stackUserID
                ) ?? .superseded
            }
            self.registerAbandonedReconnectDial(race.abandoned)
            guard !Task.isCancelled,
                  self.connectionRecoveryOwner.isCurrent(attempt) else { return }
            self.settleRoamingRelaySwap(
                attempt: attempt,
                outcome: race.value ?? .failed(.timedOut),
                stackUserID: stackUserID
            )
        }
        connectionRecoveryOwner.install(task, for: attempt)
        startConnectionRecoveryAttemptDeadline(attempt)
        return true
    }

    /// The replacement dial: the SAME stored-pairing route synthesis a normal
    /// reconnect performs (relay method = the one synthesized WebSocket
    /// route), connected in make-before-break mode so the serving session is
    /// only displaced by an admitted, authenticated replacement.
    private func performRoamingRelaySwapDial(
        attempt: MobileConnectionRecoveryOwner.Attempt,
        stackUserID: String?
    ) async -> StoredMacReconnectOutcome {
        guard let pairedMacStore else { return .failed(.noRoute) }
        guard isSignedIn,
              let scope = await currentScopeSnapshot(userID: stackUserID) else {
            return .failed(.authorizationFailed)
        }
        guard connectionRecoveryOwner.isCurrent(attempt) else { return .superseded }
        guard let targetMacDeviceID = foregroundMacDeviceID
                ?? recoveryTargetMacDeviceID else {
            return .failed(.noRoute)
        }
        let storedMac: MobilePairedMac?
        do {
            storedMac = try await pairedMacStore.activeMac(
                stackUserID: scope.userID,
                teamID: scope.teamID
            )
        } catch {
            return .failed(.unknown)
        }
        guard connectionRecoveryOwner.isCurrent(attempt),
              await isScopeCurrent(scope) else {
            return .superseded
        }
        guard let storedMac,
              cmxCanonicalDeviceID(storedMac.macDeviceID)
                == cmxCanonicalDeviceID(targetMacDeviceID) else {
            return .failed(.noRoute)
        }
        // Roaming is scoped to the relay method; anything else (a method
        // change racing the network change) falls back to ordinary recovery
        // semantics by failing this attempt while the old session stays.
        guard connectionMethod(for: storedMac) == .relay else {
            return .failed(.unsupportedRoute)
        }
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        return await connectStoredMacOutcome(
            name: storedMac.displayName ?? storedMac.macDeviceID,
            routes: orderedReconnectRoutes(
                for: storedMac,
                supportedKinds: supportedKinds
            ),
            pairedMacDeviceID: storedMac.macDeviceID,
            instanceTag: storedMac.instanceTag,
            legacyTailscaleRoutes: storedMac.legacyTailscaleRoutes ?? [],
            automaticReconnectAccountID: scope.userID,
            knownPairing: storedMac,
            makeBeforeBreak: true,
            ifStillCurrent: { [weak self] in
                self?.connectionRecoveryOwner.isCurrent(attempt) ?? false
            }
        )
    }

    /// Settles one roaming attempt. Success flows into the shared
    /// subscription-validation phase; failure keeps the still-serving old
    /// session untouched, unless the old session died mid-dial, in which case
    /// recovery escalates to the ordinary teardown + automatic-retry path.
    private func settleRoamingRelaySwap(
        attempt: MobileConnectionRecoveryOwner.Attempt,
        outcome: StoredMacReconnectOutcome,
        stackUserID: String?
    ) {
        defer { applyConnectionRecoveryOwnerState() }
        switch outcome {
        case .connected:
            MobileDebugLog.anchormux(
                "roaming.swap adopted attempt=\(attempt.id.uuidString)"
            )
            _ = settleSuccessfulConnectionRecovery(
                attempt,
                connectionGeneration: connectionGeneration
            )
        case .superseded:
            roamingSwapGapProbe = nil
            _ = connectionRecoveryOwner.complete(attempt)
        case .failed(let failure):
            roamingSwapGapProbe = nil
            let servingConnectionSurvived = connectionState == .connected
                && remoteClient != nil
                && !roamingSwapOldClientDied
            if servingConnectionSurvived {
                MobileDebugLog.anchormux(
                    "roaming.swap failed; serving connection retained "
                        + "failure=\(failure.rawValue)"
                )
                // Diagnostics record the failed replacement, but the owner
                // completes to idle: the connection the user sees is still
                // healthy, so neither reconnecting UI nor the failure banner
                // may appear, and no automatic redial is owed (the next path
                // change or a real liveness failure re-enters recovery).
                recordConnectionRecoveryFailed(attempt, failure: failure)
                _ = connectionRecoveryOwner.complete(attempt)
            } else {
                MobileDebugLog.anchormux(
                    "roaming.swap failed after serving connection died; "
                        + "escalating failure=\(failure.rawValue)"
                )
                if connectionState == .connected {
                    connectionState = .disconnected
                    macConnectionStatus = .unavailable
                    clearRemoteConnectionContext()
                }
                guard failConnectionRecovery(attempt, failure: failure) else {
                    return
                }
                armAutomaticReconnectRetryAfterFailedAttempt(
                    failure: failure,
                    stackUserID: stackUserID
                )
            }
        }
    }

    /// Logs the observable roaming handoff gap once the first event lands on
    /// the replacement connection: `gap_ms` spans last-event-before-swap (or
    /// dial start for an idle stream) to first-event-after, `dial_ms` is the
    /// parallel dial's cost while the old session still served, `resume_ms`
    /// is swap commit to first event.
    func resolveRoamingSwapGapIfPending() {
        guard let probe = roamingSwapGapProbe,
              let swapCommittedAt = probe.swapCommittedAt else { return }
        roamingSwapGapProbe = nil
        let now = runtime?.now() ?? Date()
        let gapBaseline = probe.lastEventBeforeSwapAt ?? probe.dialStartedAt
        let gapMs = Int(max(0, now.timeIntervalSince(gapBaseline)) * 1_000)
        let dialMs = Int(
            max(0, swapCommittedAt.timeIntervalSince(probe.dialStartedAt)) * 1_000
        )
        let resumeMs = Int(max(0, now.timeIntervalSince(swapCommittedAt)) * 1_000)
        MobileDebugLog.anchormux(
            "roaming.swap gap_ms=\(gapMs) dial_ms=\(dialMs) resume_ms=\(resumeMs)"
        )
    }
}

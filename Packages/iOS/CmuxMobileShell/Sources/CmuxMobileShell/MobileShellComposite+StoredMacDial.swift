import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import Foundation

/// Set when one saved Mac's dial outlives its own deadline. The abandoned
/// dial checks it on every current-attempt check, so it can never adopt a
/// connection or publish failure state after the next Mac has started.
@MainActor
final class StoredMacDialExpiry {
    var expired = false
}

/// Loads the post-failure route refresh snapshot once per reconnect pass and
/// shares it between saved Macs, including a Mac whose dial was abandoned.
@MainActor
final class ReconnectRefreshSnapshotLoader {
    private let load: @MainActor () async -> ReconnectRefreshSnapshot?
    private var task: Task<ReconnectRefreshSnapshot?, Never>?

    init(_ load: @escaping @MainActor () async -> ReconnectRefreshSnapshot?) {
        self.load = load
    }

    func snapshot() async -> ReconnectRefreshSnapshot? {
        if let task { return await task.value }
        let task = Task { @MainActor [load] in await load() }
        self.task = task
        return await task.value
    }
}

/// One saved Mac's dial inside a reconnect pass.
struct StoredMacCandidateDial: Sendable {
    /// `nil` when no route was dialed.
    var outcome: StoredMacReconnectOutcome?
    var attemptedIroh = false
    /// The Mac is a legacy private-network pairing the registry confirms has
    /// no Iroh route, so it needs a Mac update before it can reconnect.
    var needsMacUpdate = false
}

@MainActor
extension MobileShellComposite {
    /// The per-Mac dial deadline, as a sleep for ``ZeroTouchDialRace``.
    func macDialDeadline() -> ZeroTouchDialRace.DialDeadline {
        let (nanoseconds, sleep) = macDialDeadlineSleep()
        return { try await sleep(nanoseconds) }
    }

    private func macDialDeadlineSleep() -> (UInt64, RPCTaskTimeout.Sleep) {
        let nanoseconds = runtime?.macDialDeadlineNanoseconds ?? 10_000_000_000
        let sleep: RPCTaskTimeout.Sleep = { [runtime] nanoseconds in
            if let runtime {
                try await runtime.sleepUntilMacDialDeadline(nanoseconds: nanoseconds)
            } else {
                try await RPCTaskTimeout.continuousClockSleep(nanoseconds: nanoseconds)
            }
        }
        return (nanoseconds, sleep)
    }

    /// Tracks an abandoned dial until it resolves, so a persistently wedged
    /// transport cannot accumulate an unbounded set of retained reconnect
    /// tasks across automatic retries. On resolution, if the shell is still
    /// signed in and disconnected, the automatic retry loop is re-armed
    /// (covers the case where retries were paused at the ceiling).
    func registerAbandonedReconnectDial<Value: Sendable>(_ task: Task<Value, Never>?) {
        guard let task else { return }
        abandonedReconnectDialCount += 1
        Task { @MainActor [weak self] in
            _ = await task.value
            guard let self else { return }
            self.abandonedReconnectDialCount = max(0, self.abandonedReconnectDialCount - 1)
            // Re-arm the retry loop directly through the coalesced recovery
            // entry, NEVER by recording backoff: a backoff write here can land
            // mid-manual-retry and re-block the dial the user just requested
            // (manual retries clear backoff on entry). Skip when any attempt
            // or scheduled retry is already active, including a stored-Mac
            // reconnect or a user's Mac switch that owns the connection now.
            guard self.isSignedIn, self.connectionState != .connected,
                  !self.connectionRecoveryOwner.isRedialingOrValidating,
                  self.storedMacReconnectGenerationsInFlight.isEmpty,
                  !self.isMacSwitchInFlight,
                  self.automaticReconnectRetryTask == nil else { return }
            self.recoverMobileConnection(trigger: .automaticBackoffExpired)
        }
    }

    /// Dials one saved Mac, local routes then refreshed routes, under that
    /// Mac's own deadline. A Mac that accepts the transport but never answers
    /// used to hold the whole reconnect attempt, so live Macs behind it were
    /// never dialed. On expiry the dial is abandoned (the next Mac's connect
    /// supersedes its client) and the pass moves on.
    func dialSavedCandidateUnderDeadline(
        _ mac: MobilePairedMac,
        storedRoutes: [CmxAttachRoute],
        isFirstCandidate: Bool,
        usesStrictTailscale: Bool,
        scope: MobileShellScopeSnapshot,
        generation: Int,
        refreshSnapshot: ReconnectRefreshSnapshotLoader
    ) async -> StoredMacCandidateDial {
        let expiry = StoredMacDialExpiry()
        let (nanoseconds, sleep) = macDialDeadlineSleep()
        let race = await Self.raceAgainstDeadline(
            nanoseconds: nanoseconds,
            sleep: sleep
        ) { [weak self] in
            await self?.dialSavedCandidate(
                mac,
                storedRoutes: storedRoutes,
                isFirstCandidate: isFirstCandidate,
                usesStrictTailscale: usesStrictTailscale,
                scope: scope,
                generation: generation,
                refreshSnapshot: refreshSnapshot,
                expiry: expiry
            ) ?? StoredMacCandidateDial(outcome: .superseded)
        }
        if let value = race.value { return value }
        expiry.expired = true
        registerAbandonedReconnectDial(race.abandoned)
        return StoredMacCandidateDial(
            outcome: race.wasCancelled ? .superseded : .failed(.timedOut),
            attemptedIroh: !usesStrictTailscale
                && storedRoutes.contains { $0.kind == .iroh }
        )
    }

    private func dialSavedCandidate(
        _ mac: MobilePairedMac,
        storedRoutes: [CmxAttachRoute],
        isFirstCandidate: Bool,
        usesStrictTailscale: Bool,
        scope: MobileShellScopeSnapshot,
        generation: Int,
        refreshSnapshot: ReconnectRefreshSnapshotLoader,
        expiry: StoredMacDialExpiry
    ) async -> StoredMacCandidateDial {
        let isCurrent: () -> Bool = { [weak self] in
            !expiry.expired && self?.storedMacReconnectGeneration == generation
        }
        var dial = StoredMacCandidateDial()
        // Tailscale Only excludes Iroh for every pairing. Automatic may
        // use Iroh, while Direct has its own address allowlist.
        let irohReconnectIsBlocked = usesStrictTailscale
            || automaticIrohReconnectIsBlocked(accountID: scope.userID)
        let localRoutes = storedRoutes.filter {
            !irohReconnectIsBlocked || $0.kind != .iroh
        }
        let localHasIroh = localRoutes.contains { $0.kind == .iroh }
        // Raw Tailscale/TCP is bearer-capable only for an exact local route
        // retained by the pairing. A selected Tailscale method has no Iroh
        // fallback, so an absent or stale grant remains unavailable.
        let localCanConnectSecurely = localHasIroh
            || localRoutes.contains { $0.kind == .debugLoopback }
            || localRoutes.contains { route in
                Self.legacyTailscaleAuthorizationEvidence(
                    for: route,
                    macDeviceID: mac.macDeviceID,
                    persistedRoutes: mac.legacyTailscaleRoutes ?? []
                ) != nil
            }
        let isLegacyPrivateNetworkPairing = !mac.routes.contains { $0.kind == .iroh }
            && mac.routes.contains { $0.kind == .tailscale }
        if localCanConnectSecurely {
            dial.attemptedIroh = localHasIroh
            dial.outcome = await connectStoredMacOutcome(
                name: mac.displayName ?? mac.macDeviceID,
                routes: localRoutes,
                pairedMacDeviceID: mac.macDeviceID,
                instanceTag: mac.instanceTag,
                legacyTailscaleRoutes: mac.legacyTailscaleRoutes ?? [],
                automaticReconnectAccountID: scope.userID,
                knownPairing: mac,
                ifStillCurrent: isCurrent
            )
        }
        guard connectionState != .connected,
              isCurrent(),
              !usesStrictTailscale,
              !automaticIrohReconnectIsBlocked(accountID: scope.userID) else { return dial }
        switch await freshReconnectRoutesAfterLocalFailure(
            for: mac,
            scope: scope,
            snapshot: await refreshSnapshot.snapshot()
        ) {
        case .refreshedRoutes(let refreshedRoutes):
            dial.attemptedIroh = dial.attemptedIroh
                || refreshedRoutes.contains { $0.kind == .iroh }
            dial.outcome = await connectStoredMacOutcome(
                name: mac.displayName ?? mac.macDeviceID,
                routes: refreshedRoutes,
                pairedMacDeviceID: mac.macDeviceID,
                instanceTag: mac.instanceTag,
                legacyTailscaleRoutes: mac.legacyTailscaleRoutes ?? [],
                automaticReconnectAccountID: scope.userID,
                knownPairing: mac,
                ifStillCurrent: isCurrent
            )
        case .confirmedMissingIroh:
            dial.outcome = .failed(.unsupportedRoute)
            dial.needsMacUpdate = isLegacyPrivateNetworkPairing && isFirstCandidate
        case .inconclusive:
            break
        }
        return dial
    }
}

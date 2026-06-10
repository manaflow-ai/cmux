import CMUXMobileCore
import Foundation

/// Two-phase pairing connect over a ticket's candidate routes: race a
/// credential-free probe to pick the winning route, then run the credentialed
/// finalize on that single winner only.
///
/// Racing the credentialed request itself would hand the owner's Stack bearer
/// token (and the attach ticket's token) to every candidate endpoint after
/// only the stagger, even when the primary route was about to succeed. The
/// candidate endpoints are unverified (a stale or reassigned address can host
/// a different machine entirely), so phase 1 races only an unauthenticated
/// probe; credentials are sent to at most one endpoint at a time, and only one
/// that already proved it speaks the cmux mobile protocol. That is strictly
/// less exposure than the old sequential loop, which sent the credentialed
/// request to every endpoint it could reach, in order, until one succeeded.
///
/// When the finalize fails route-locally (for example the probe winner is the
/// wrong Mac at a stale address and rejects the credential), the failed route
/// is excluded and the probe race re-runs over the remaining routes, so one
/// bad endpoint cannot veto a viable sibling. A route-independent finalize
/// failure (the locally checked ticket expiry) stops the fallback immediately.
struct MobilePairingTwoPhaseRace: Sendable {
    /// The single-phase racer used for the probe round(s).
    var race: MobilePairingRouteRace

    /// Creates a two-phase racer.
    /// - Parameter race: The probe-phase racer (stagger, route cap, clock).
    init(race: MobilePairingRouteRace) {
        self.race = race
    }

    /// Runs the probe race, then the finalize on the winner, falling back to
    /// the remaining routes when the finalize fails route-locally.
    ///
    /// - Parameters:
    ///   - routes: Candidate routes in priority order. At most the race's
    ///     route cap are ever contacted, across all fallback rounds, so a
    ///     crafted ticket cannot extend the loop.
    ///   - endsRace: Returns `true` for route-independent failures (see
    ///     ``MobilePairingRouteAttempt/failureEndsRouteRace(_:)``); applies to
    ///     probe failures within a round and to finalize failures between
    ///     rounds.
    ///   - probe: Dials one route WITHOUT credentials and proves the endpoint
    ///     speaks the protocol. Must clean up its own resources on failure and
    ///     be cancellation-responsive for losers to be reaped promptly.
    ///   - onDiscardedProbe: Tears down a probe success that did not become
    ///     the returned win (a race loser that completed late, or a winner
    ///     whose finalize failed).
    ///   - finalize: Runs the credentialed phase over the winning probe. Must
    ///     not tear down the probe's resources on failure; the orchestrator
    ///     owns that via `onDiscardedProbe`.
    /// - Returns: The first winner's finalized value.
    /// - Throws: `CancellationError` when the caller's task is cancelled, or
    ///   ``MobilePairingRouteRaceFailure`` carrying every probe and finalize
    ///   failure across rounds when no route paired.
    func run<Probe: Sendable, Win: Sendable>(
        routes: [CmxAttachRoute],
        endsRace: @escaping @Sendable (any Error) -> Bool,
        probe: @escaping @Sendable (CmxAttachRoute) async throws -> Probe,
        onDiscardedProbe: @escaping @Sendable (Probe) async -> Void,
        finalize: @escaping @Sendable (CmxAttachRoute, Probe) async throws -> Win
    ) async throws -> Win {
        // Cap the total endpoints contacted across all fallback rounds, not
        // just per round, so exclusions cannot walk a crafted ticket's
        // thousand routes eight at a time.
        let candidateRoutes = Array(routes.prefix(max(1, race.maxRoutes)))
        var remaining = candidateRoutes
        var finalizeFailures: [MobilePairingRouteRaceFailure.RouteFailure] = []

        func originalIndex(of route: CmxAttachRoute) -> Int {
            candidateRoutes.firstIndex(of: route) ?? candidateRoutes.count
        }

        func combinedFailure(
            probeFailures: [MobilePairingRouteRaceFailure.RouteFailure],
            raceEndingFailure: MobilePairingRouteRaceFailure.RouteFailure?
        ) -> MobilePairingRouteRaceFailure {
            MobilePairingRouteRaceFailure(
                failures: (finalizeFailures + probeFailures)
                    .sorted { $0.routeIndex < $1.routeIndex },
                raceEndingFailure: raceEndingFailure
            )
        }

        while true {
            let winner: (route: CmxAttachRoute, probe: Probe)
            do {
                winner = try await race.run(
                    routes: remaining,
                    endsRace: endsRace,
                    onDiscardedSuccess: { (loser: (route: CmxAttachRoute, probe: Probe)) in
                        await onDiscardedProbe(loser.probe)
                    },
                    attempt: { route in (route: route, probe: try await probe(route)) }
                )
            } catch let probeFailure as MobilePairingRouteRaceFailure {
                // Re-index this round's failures against the full candidate
                // list so they sort consistently with finalize failures from
                // earlier rounds.
                let remapped = probeFailure.failures.map {
                    MobilePairingRouteRaceFailure.RouteFailure(
                        routeIndex: originalIndex(of: $0.route),
                        route: $0.route,
                        error: $0.error
                    )
                }
                throw combinedFailure(
                    probeFailures: remapped,
                    raceEndingFailure: probeFailure.raceEndingFailure
                )
            }

            do {
                return try await finalize(winner.route, winner.probe)
            } catch {
                await onDiscardedProbe(winner.probe)
                // The caller's cancellation must surface as cancellation, not
                // as a route failure that triggers another round.
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                let failure = MobilePairingRouteRaceFailure.RouteFailure(
                    routeIndex: originalIndex(of: winner.route),
                    route: winner.route,
                    error: error
                )
                finalizeFailures.append(failure)
                if endsRace(error) {
                    throw combinedFailure(probeFailures: [], raceEndingFailure: failure)
                }
                remaining.removeAll { $0 == winner.route }
                if remaining.isEmpty {
                    throw combinedFailure(probeFailures: [], raceEndingFailure: nil)
                }
            }
        }
    }
}

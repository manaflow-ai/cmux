import CMUXMobileCore
import Foundation

/// Happy-Eyeballs-style first-success race over a pairing ticket's candidate
/// routes.
///
/// The old pairing loop dialed routes *sequentially*, so every dead route's
/// connect/request timeout stacked into one opaque wait before the next route
/// even started. This racer starts the highest-priority route immediately and
/// each subsequent route after a short ``stagger``, so a healthy lower-priority
/// route (for example loopback in the simulator while an unroutable Tailscale
/// address times out) wins in milliseconds instead of minutes. The first
/// successful attempt wins; every other attempt is cancelled and joined before
/// the race returns, and a success that lands after the winner is handed to
/// `onDiscardedSuccess` so its connection can be torn down rather than leaked.
///
/// The stagger sleeps on an injected ``clock`` so tests drive the race with
/// virtual time instead of real waiting.
struct MobilePairingRouteRace: Sendable {
    /// Delay between starting successive route attempts, in priority order.
    /// 250ms keeps the priority order meaningful (a healthy primary route wins
    /// before the secondary even dials) while letting a dead primary route cost
    /// only the stagger, not its full timeout, before alternatives start.
    var stagger: Duration
    /// The clock the stagger delays sleep on (virtual in tests).
    var clock: any Clock<Duration>

    /// Creates a racer.
    /// - Parameters:
    ///   - stagger: Delay between starting successive route attempts.
    ///   - clock: The clock stagger delays sleep on.
    init(
        stagger: Duration = .milliseconds(250),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.stagger = stagger
        self.clock = clock
    }

    /// Races `attempt` over `routes`, first success wins.
    ///
    /// - Parameters:
    ///   - routes: Candidate routes in priority order; index 0 starts with no
    ///     delay, index `n` starts after `n * stagger`.
    ///   - endsRace: Returns `true` for failures that are definitive for the
    ///     *host* rather than the route (auth rejection, expired ticket, an RPC
    ///     error answer): every other route would get the same answer, so the
    ///     race ends immediately instead of waiting out the remaining attempts.
    ///   - onDiscardedSuccess: Cleanup for a success that completed after the
    ///     winner was chosen (close its connection so it does not leak).
    ///   - attempt: Dials one route. Must be cancellation-responsive for losers
    ///     to be reaped promptly.
    /// - Returns: The winning attempt's value.
    /// - Throws: `CancellationError` when the caller's task is cancelled, or
    ///   ``MobilePairingRouteRaceFailure`` when every attempt failed.
    func run<Success: Sendable>(
        routes: [CmxAttachRoute],
        endsRace: @escaping @Sendable (any Error) -> Bool,
        onDiscardedSuccess: @escaping @Sendable (Success) async -> Void,
        attempt: @escaping @Sendable (CmxAttachRoute) async throws -> Success
    ) async throws -> Success {
        guard !routes.isEmpty else {
            throw MobilePairingRouteRaceFailure(failures: [], raceEndingFailure: nil)
        }
        let stagger = stagger
        let clock = clock
        return try await withThrowingTaskGroup(of: RouteOutcome<Success>.self) { group in
            for (index, route) in routes.enumerated() {
                group.addTask {
                    do {
                        if index > 0 {
                            try await clock.sleep(for: stagger * index, tolerance: nil)
                        }
                        return RouteOutcome(index: index, route: route, result: .success(try await attempt(route)))
                    } catch {
                        return RouteOutcome(index: index, route: route, result: .failure(error))
                    }
                }
            }
            var winner: Success?
            var failures: [MobilePairingRouteRaceFailure.RouteFailure] = []
            var raceEndingFailure: MobilePairingRouteRaceFailure.RouteFailure?
            // Children never throw (outcomes carry their errors), so this loop
            // drains every child: losers are joined before returning, and a
            // success that lost the race is explicitly discarded, not leaked.
            while let outcome = try await group.next() {
                switch outcome.result {
                case let .success(value):
                    if winner == nil {
                        winner = value
                        group.cancelAll()
                    } else {
                        await onDiscardedSuccess(value)
                    }
                case let .failure(error):
                    let failure = MobilePairingRouteRaceFailure.RouteFailure(
                        routeIndex: outcome.index,
                        route: outcome.route,
                        error: error
                    )
                    failures.append(failure)
                    if winner == nil, raceEndingFailure == nil, endsRace(error) {
                        raceEndingFailure = failure
                        group.cancelAll()
                    }
                }
            }
            if let winner { return winner }
            // The caller's cancellation must surface as cancellation (silent in
            // the pairing UI), not as an all-routes-failed error built from the
            // children's cancellation noise.
            try Task.checkCancellation()
            throw MobilePairingRouteRaceFailure(
                failures: failures.sorted { $0.routeIndex < $1.routeIndex },
                raceEndingFailure: raceEndingFailure
            )
        }
    }

    private struct RouteOutcome<Success: Sendable>: Sendable {
        let index: Int
        let route: CmxAttachRoute
        let result: Result<Success, any Error>
    }
}

/// Thrown by ``MobilePairingRouteRace`` when every route attempt failed.
///
/// Carries each route's failure so the caller can surface the single most
/// actionable one (``representative``) instead of whichever route happened to
/// finish last, which under concurrent attempts is often a low-signal timeout
/// or the cancellation noise of a reaped loser.
struct MobilePairingRouteRaceFailure: Error {
    /// One route's terminal failure within the race.
    struct RouteFailure: Sendable {
        /// The route's index in the priority-ordered candidate list.
        let routeIndex: Int
        /// The route the attempt dialed.
        let route: CmxAttachRoute
        /// The error the attempt failed with.
        let error: any Error
    }

    /// Every failed attempt, in route-priority order.
    let failures: [RouteFailure]
    /// The failure that ended the race early because it was definitive for the
    /// host (auth rejection, expired ticket, an RPC error answer), if any.
    let raceEndingFailure: RouteFailure?

    /// The single failure the pairing UI should classify and show.
    ///
    /// A race-ending failure wins outright (the host answered; that answer is
    /// the truth). Otherwise the failure whose classified category carries the
    /// most user-actionable signal wins, with the route priority breaking ties,
    /// so "cmux isn't running on your Mac" beats a sibling route's generic
    /// timeout instead of being buried by it.
    var representative: RouteFailure? {
        if let raceEndingFailure { return raceEndingFailure }
        return failures.min { lhs, rhs in
            let lhsRank = Self.actionabilityRank(of: lhs)
            let rhsRank = Self.actionabilityRank(of: rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.routeIndex < rhs.routeIndex
        }
    }

    /// Lower ranks are more specific/actionable for the user. Definitive host
    /// answers rank first, reachability diagnoses next, bare timeouts and
    /// generic failures after, and cancellation noise last (a reaped loser must
    /// never be the failure the user reads).
    private static func actionabilityRank(of failure: RouteFailure) -> Int {
        switch MobilePairingFailureCategory.classify(error: failure.error, route: failure.route) {
        case .ticketExpired, .accountMismatch, .authFailed:
            return 0
        case .invalidCode, .unsupportedRoute, .noSupportedRoute:
            return 1
        case .localNetworkBlocked:
            return 2
        case .listenerNotRunning:
            return 3
        case .connectionDropped:
            return 4
        case .dnsFailed:
            return 5
        case .hostUnreachable:
            return 6
        case .handshakeTimedOut:
            return 7
        case .offline:
            return 8
        case .unknown:
            return 9
        case .cancelled:
            return 10
        }
    }
}

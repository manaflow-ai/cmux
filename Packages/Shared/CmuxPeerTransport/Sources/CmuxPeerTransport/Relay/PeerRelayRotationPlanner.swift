public import CmuxPeerTransportCore

/// One endpoint mutation in a relay credential rotation.
public enum PeerRelayRotationStep: Equatable, Sendable {
    /// Insert (or replace, keyed by URL) one relay configuration.
    case insertRelay(PeerRelayConfig)

    /// Wait until the endpoint reports a healthy home relay on the
    /// refreshed configuration before tearing anything down.
    case awaitHomeRelayHealthy

    /// Remove the relay map entry for one URL.
    case removeRelay(url: String)
}

/// The seam the endpoint executor implements to run rotation steps.
///
/// Stock iroh-ffi v1.1.0 has no in-place token replacement (a live relay
/// actor captures its token at start), so the executor maps these onto
/// `RelayMap` insert/remove plus a home-relay health probe.
public protocol PeerRelayApplying: Sendable {
    /// Inserts one relay configuration into the endpoint's relay map.
    func insertRelay(_ config: PeerRelayConfig) async throws

    /// Removes the relay map entry for one URL.
    func removeRelay(url: String) async throws

    /// Returns once the home relay is healthy on the current relay map.
    func homeRelayHealthy() async throws
}

/// An ordered make-before-break rotation with its recovery counterpart,
/// fenced to the endpoint runtime generation it was planned for.
public struct PeerRelayRotationPlan: Equatable, Sendable {
    /// The endpoint runtime generation this plan was computed against.
    public let generation: PeerTransportGeneration

    /// Ordered forward steps: insert refreshed, await health, remove stale.
    public let steps: [PeerRelayRotationStep]

    /// Ordered recovery steps restoring the prior applied set.
    public let rollback: [PeerRelayRotationStep]

    /// True when the refreshed set already equals the applied set.
    public var isNoOp: Bool { steps.isEmpty }

    /// The forward steps, or `nil` when the endpoint generation has advanced
    /// since planning (a recreated endpoint owns a fresh relay map, so a
    /// stale plan must not mutate it).
    public func steps(
        ifCurrent generation: PeerTransportGeneration
    ) -> [PeerRelayRotationStep]? {
        guard generation == self.generation else { return nil }
        return steps
    }

    /// The recovery steps restoring the prior set after a forward-step
    /// failure, or `nil` when the endpoint generation has advanced.
    public func rollbackSteps(
        ifCurrent generation: PeerTransportGeneration
    ) -> [PeerRelayRotationStep]? {
        guard generation == self.generation else { return nil }
        return rollback
    }
}

/// Pure make-before-break relay rotation planning for stock iroh-ffi v1.1.0.
///
/// Emits steps only; the endpoint agent executes them through
/// ``PeerRelayApplying``. Forward order is always insert-refreshed, await
/// home-relay health, then remove stale entries, so the relay map never
/// passes through a credential-less window. Rollback reinstates the prior
/// applied set and removes refreshed-only entries.
public struct PeerRelayRotationPlanner: Sendable {
    /// Creates a stateless rotation planner.
    public init() {}

    /// Plans a rotation from `applied` to `refreshed`.
    ///
    /// - An identical set (same URLs and tokens) yields a no-op plan.
    /// - An empty `refreshed` set yields a pure removal plan (fail-closed to
    ///   direct-only), with no health await.
    /// - Otherwise, refreshed configurations are inserted first (a same-URL
    ///   insert replaces the map entry with the fresh token), the home relay
    ///   is confirmed healthy, and only then are stale URLs removed.
    ///
    /// - Parameters:
    ///   - applied: The relay configurations currently applied to the endpoint.
    ///   - refreshed: The replacement configurations from a fresh credential plan.
    ///   - generation: The endpoint runtime generation observed at planning time.
    public func plan(
        applied: [PeerRelayConfig],
        refreshed: [PeerRelayConfig],
        generation: PeerTransportGeneration
    ) -> PeerRelayRotationPlan {
        guard Set(refreshed) != Set(applied) else {
            return PeerRelayRotationPlan(generation: generation, steps: [], rollback: [])
        }
        let appliedURLs = Set(applied.map(\.url))
        let refreshedURLs = Set(refreshed.map(\.url))

        var steps: [PeerRelayRotationStep] = refreshed.map { .insertRelay($0) }
        if !refreshed.isEmpty {
            steps.append(.awaitHomeRelayHealthy)
        }
        for config in applied where !refreshedURLs.contains(config.url) {
            steps.append(.removeRelay(url: config.url))
        }

        var rollback: [PeerRelayRotationStep] = applied.map { .insertRelay($0) }
        for config in refreshed where !appliedURLs.contains(config.url) {
            rollback.append(.removeRelay(url: config.url))
        }

        return PeerRelayRotationPlan(
            generation: generation,
            steps: steps,
            rollback: rollback
        )
    }
}

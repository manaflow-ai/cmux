import Foundation

/// The endpoint the launch's prewarm found, kept for the next handshake of its host (``AcpmuxHost``, CMUX-571).
///
/// The app prewarms its host at launch, and a restored chat's page sends its handshake about a
/// second later, after its page loaded. The prewarm's lookup had settled by then, so the handshake
/// ran the whole lookup again (home adoption, `_acpmux/status`, enrollments, the peer-checked
/// endpoint read) before the chat could open its transport. The endpoint is the running daemon's
/// until it exits, so the first handshake after the launch prewarm takes it instead.
///
/// One handshake takes it, and only within ``freshFor`` of the prewarm. ``drop()`` forgets it: a
/// restart of the daemon, and any handshake or reconnect that looks up itself, so a later one
/// (the person-proof recovery) always looks up in full. A prewarm whose lookup settles after a
/// drop keeps nothing.
nonisolated struct AcpmuxPrewarmedEndpoint: Sendable {
    /// How long after its prewarm a kept endpoint may answer a handshake. A restored chat asks
    /// within a few seconds of launch; a later handshake looks up again.
    static let freshFor: Duration = .seconds(15)

    private var kept: (endpoint: AcpmuxWebEndpoint, at: ContinuousClock.Instant)?
    /// Counts ``drop()``: a prewarm reads it before its lookup and keeps its endpoint only when
    /// nothing dropped in between.
    private(set) var generation = 0

    /// Keeps `endpoint`, found by a prewarm that started when ``generation`` was `before`.
    mutating func keep(_ endpoint: AcpmuxWebEndpoint, at now: ContinuousClock.Instant, unlessDroppedSince before: Int) {
        guard before == generation else { return }
        kept = (endpoint, now)
    }

    /// The kept endpoint when it is fresh at `now`; it is gone after this either way.
    mutating func take(at now: ContinuousClock.Instant) -> AcpmuxWebEndpoint? {
        defer { kept = nil }
        guard let kept, now - kept.at <= Self.freshFor else { return nil }
        return kept.endpoint
    }

    /// Nothing kept answers a handshake any more, and a prewarm looking now keeps nothing.
    mutating func drop() {
        kept = nil
        generation += 1
    }
}

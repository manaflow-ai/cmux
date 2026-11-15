import Foundation

/// The endpoint a prewarm found, kept for the next handshake of its host (``AcpmuxHost``, CMUX-571).
///
/// The app prewarms its host at launch, and a restored chat's page sends its handshake about a
/// second later, after its page loaded. The prewarm's lookup had settled by then, so the handshake
/// ran the whole lookup again (home adoption, `_acpmux/status`, enrollments, the peer-checked
/// endpoint read) before the chat could open its transport. The endpoint is the running daemon's
/// until it exits, so the first handshake after a prewarm takes it instead.
///
/// One handshake takes it, and only within ``freshFor`` of the prewarm: a daemon that exits after
/// it fails that one page's connect, and the page's next handshake looks up again. A restart of
/// the daemon drops it, and a prewarm that settles across a restart keeps nothing.
nonisolated struct AcpmuxPrewarmedEndpoint: Sendable {
    /// How long after its prewarm a kept endpoint may answer a handshake. A restored chat asks
    /// within a few seconds of launch; a later handshake looks up again.
    static let freshFor: Duration = .seconds(15)

    private var kept: (endpoint: AcpmuxWebEndpoint, at: ContinuousClock.Instant)?
    /// Counts ``drop()``: a prewarm reads it before its lookup and keeps its endpoint only when
    /// no restart came in between.
    private(set) var restarts = 0

    /// Keeps `endpoint`, found by a prewarm that started when ``restarts`` was `restartsBefore`.
    mutating func keep(_ endpoint: AcpmuxWebEndpoint, at now: ContinuousClock.Instant, unlessRestartedSince restartsBefore: Int) {
        guard restartsBefore == restarts else { return }
        kept = (endpoint, now)
    }

    /// The kept endpoint when it is fresh at `now`; it is gone after this either way.
    mutating func take(at now: ContinuousClock.Instant) -> AcpmuxWebEndpoint? {
        defer { kept = nil }
        guard let kept, now - kept.at <= Self.freshFor else { return nil }
        return kept.endpoint
    }

    /// The daemon restarts: nothing kept answers a handshake any more.
    mutating func drop() {
        kept = nil
        restarts += 1
    }
}

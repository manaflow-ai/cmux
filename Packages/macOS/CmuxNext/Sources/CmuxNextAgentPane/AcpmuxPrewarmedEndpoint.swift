import Foundation

/// The endpoint a host's lookup found, kept for its next handshakes (``AcpmuxHost``, CMUX-571).
///
/// The app prewarms its host at launch, and a restored chat's page sends its handshake about a
/// second later, after its page loaded. The prewarm's lookup had settled by then, so the handshake
/// ran the whole lookup again (home adoption, `_acpmux/status`, enrollments, the peer-checked
/// endpoint read) before the chat could open its transport. The endpoint is the running daemon's
/// until it exits, so the first handshake after the launch prewarm takes it instead.
///
/// It also answers every later handshake while the daemon it came from runs (`daemon`: that
/// daemon's pid, which took this launch's person key). Every new chat, tab and reload paid the
/// whole lookup before (Leo, 2026-11-21, on "Waiting for the agent service (1:07)": "why does it
/// take any time at all to \"connect\""): on a loaded Mac `_acpmux/status` answered in 0.2 to
/// 51 s, and the composer waited on it although the endpoint had not changed. A kept endpoint
/// with no daemon (the launch prewarm's, before its daemon took the key) answers one handshake,
/// within ``freshFor``.
///
/// ``drop()`` forgets it: a restart of the daemon, a reconnect, and any handshake that looks up
/// itself. A lookup that settles after a drop keeps nothing.
nonisolated struct AcpmuxPrewarmedEndpoint: Sendable {
    /// How long after its prewarm a kept endpoint of no known daemon may answer a handshake. A
    /// restored chat asks within a few seconds of launch; a later handshake looks up again.
    static let freshFor: Duration = .seconds(15)

    private var kept: (endpoint: AcpmuxWebEndpoint, at: ContinuousClock.Instant, daemon: Int32?)?
    /// Counts ``drop()``: a lookup reads it before it starts and keeps its endpoint only when
    /// nothing dropped in between.
    private(set) var generation = 0

    /// Keeps `endpoint`, found by a lookup that started when ``generation`` was `before`, from the
    /// daemon `daemon` (nil: not known yet).
    mutating func keep(_ endpoint: AcpmuxWebEndpoint, at now: ContinuousClock.Instant, daemon: Int32? = nil,
                       unlessDroppedSince before: Int) {
        guard before == generation else { return }
        kept = (endpoint, now, daemon)
    }

    /// The kept endpoint for a handshake at `now` while `daemon` runs (nil: none known). One kept
    /// from that same daemon stays for the next handshake; any other answers once, when fresh.
    mutating func take(at now: ContinuousClock.Instant, daemon: Int32? = nil) -> AcpmuxWebEndpoint? {
        guard let kept else { return nil }
        if let from = kept.daemon, from == daemon { return kept.endpoint }
        self.kept = nil
        guard kept.daemon == nil, now - kept.at <= Self.freshFor else { return nil }
        return kept.endpoint
    }

    /// Nothing kept answers a handshake any more, and a lookup looking now keeps nothing.
    mutating func drop() {
        kept = nil
        generation += 1
    }
}

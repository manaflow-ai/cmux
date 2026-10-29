/// When a wire stream sends its next keepalive ping.
///
/// A ping is due `interval` after the later of the last ping and the last frame the owner sent, so
/// a socket that carries frames sends no pings at all. This is Chromium's QUIC ping alarm: its
/// deadline is the keep-alive timeout after the last activity on the connection
/// (`net/third_party/quiche/src/quiche/quic/core/quic_ping_manager.cc`, `QuicPingManager::SetAlarm`).
/// A frame costs no wake: the keepalive reads the due time again when its wait ends and sleeps only
/// the remainder. CmuxIrxTransport's `IrxKeepaliveSchedule` is the same rule.
struct HomeKeepaliveSchedule: Sendable, Equatable {
    /// The quiet time before a ping.
    let interval: Duration

    /// The instant the next ping is due.
    func nextPing<Instant: InstantProtocol<Duration>>(afterPing lastPing: Instant, lastInbound: Instant?) -> Instant {
        lastPing.advanced(by: nextPing(afterPing: .zero, lastInbound: lastInbound.map { lastPing.duration(to: $0) }))
    }

    /// The time the next ping is due, for times read as durations since one start on one clock.
    func nextPing(afterPing lastPing: Duration, lastInbound: Duration?) -> Duration {
        guard let lastInbound, lastInbound > lastPing else { return lastPing + interval }
        return lastInbound + interval
    }
}

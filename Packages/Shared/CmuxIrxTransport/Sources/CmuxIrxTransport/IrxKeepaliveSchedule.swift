/// When the client keepalive sends its next probe.
///
/// A probe is due `interval` after the later of the last probe's end and the last application
/// bytes the peer sent, so a link that carries traffic sends no probes at all. This is Chromium's
/// QUIC ping alarm: its deadline is the keep-alive timeout after the last activity on the
/// connection (`net/third_party/quiche/src/quiche/quic/core/quic_ping_manager.cc`,
/// `QuicPingManager::SetAlarm`). Activity costs no wake: the keepalive reads the deadline again
/// when its wait ends and sleeps only the remainder.
struct IrxKeepaliveSchedule: Sendable, Equatable {
    /// The quiet time before a probe.
    let interval: Duration

    /// The instant the next probe is due.
    func nextProbe(
        afterProbe lastProbe: ContinuousClock.Instant,
        lastInbound: ContinuousClock.Instant?
    ) -> ContinuousClock.Instant {
        guard let lastInbound, lastInbound > lastProbe else { return lastProbe + interval }
        return lastInbound + interval
    }
}

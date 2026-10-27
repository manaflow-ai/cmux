import CmuxSafeConcurrency

/// Most recent moment the peer's application layer delivered bytes on any
/// stream of one connection.
///
/// Only application reads count: QUIC acknowledgements and transport
/// keep-alives prove the peer's network stack is up, not that the host
/// process is serving the connection. Written from every stream reader, so it
/// is a lock rather than an actor hop per read.
public final class IrxInboundActivityClock: Sendable {
    private let last = Mutex<ContinuousClock.Instant?>(nil)

    public init() {}

    public func record(at instant: ContinuousClock.Instant = .now) {
        last.withLock { last in
            if let previous = last, previous >= instant { return }
            last = instant
        }
    }

    public var lastActivity: ContinuousClock.Instant? {
        last.withLock { $0 }
    }
}

/// What one connection can prove about a period of silence.
public enum IrxConnectionSilenceEvidence: Equatable, Sendable {
    /// The peer's application layer delivered bytes during the period.
    case activity
    /// The connection closed, or liveness probes ran throughout the period
    /// and nothing from the peer's application layer arrived.
    case silent
    /// No signal covers the period, so silence proves nothing.
    case inconclusive
}

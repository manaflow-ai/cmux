/// Host-side pacing core: the encoder may consume the latest captured frame
/// only while fewer than `window` encoded frames are unacknowledged.
///
/// This is the mechanism that makes stale-frame queues unrepresentable.
/// Raw frames overwrite a single latest-frame slot for free; encoded frames
/// exist only when the link has demonstrated capacity for them. Under
/// congestion the stream converges to "newest frame, `window` deep", never
/// to a growing queue and never to a shed-and-replay cycle.
public struct SimStreamCreditGate: Sendable, Equatable {
    public private(set) var window: UInt64
    public private(set) var lastSentSequence: UInt64
    public private(set) var lastAcknowledgedSequence: UInt64

    public init(window: UInt64 = 2) {
        precondition(window >= 1, "a zero window can never send")
        self.window = window
        self.lastSentSequence = 0
        self.lastAcknowledgedSequence = 0
    }

    public var unacknowledgedCount: UInt64 {
        lastSentSequence - lastAcknowledgedSequence
    }

    public var hasCredit: Bool {
        unacknowledgedCount < window
    }

    /// Reserves the next frame sequence. Callers must only invoke this when
    /// `hasCredit` is true; the returned sequence goes on the wire.
    public mutating func consumeCredit() -> UInt64 {
        lastSentSequence += 1
        return lastSentSequence
    }

    /// Applies a cumulative ack. Regressions and acks for frames never sent
    /// are ignored so a duplicated or corrupted ack can never mint credit.
    public mutating func acknowledge(_ sequence: UInt64) {
        guard sequence > lastAcknowledgedSequence, sequence <= lastSentSequence else {
            return
        }
        lastAcknowledgedSequence = sequence
    }

    /// Forgets in-flight state (stream restart). Sequences keep growing so
    /// a late ack from before the reset still can't exceed `lastSentSequence`.
    public mutating func resetInFlight() {
        lastAcknowledgedSequence = lastSentSequence
    }
}

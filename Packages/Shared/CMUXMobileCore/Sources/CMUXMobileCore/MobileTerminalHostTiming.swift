/// Mac-side timestamps and pacing state carried on a render-grid frame so the
/// phone can split keystroke latency into per-hop stages without the Mac
/// emitting any telemetry of its own.
///
/// Attached sparingly to keep wire cost negligible: input stamps only on the
/// first frame that carries a newly accepted input marker, and a pacer sample
/// at most about once per second per surface. Every clock value is the Mac's
/// monotonic uptime in microseconds; the phone never compares these to its own
/// clock directly (see ``MobileTerminalClockOffsetEstimator``).
public struct MobileTerminalHostTiming: Codable, Equatable, Sendable {
    /// When the Mac's input lane first held the input, before the hop to the
    /// main actor that accepts it.
    public var inputReceivedMicros: UInt64?
    /// When the terminal accepted the input.
    public var inputAcceptedMicros: UInt64?
    /// When the Mac captured the render-grid frame carrying the echo.
    public var frameCapturedMicros: UInt64?
    /// When the encoded frame was handed to the connection queues. Time spent
    /// in the Mac's send queues after this point is counted as downlink.
    public var frameDispatchedMicros: UInt64?
    /// The emission pacer's state for this surface since the previous sample.
    public var pacer: MobileTerminalPacerSample?

    public init(
        inputReceivedMicros: UInt64? = nil,
        inputAcceptedMicros: UInt64? = nil,
        frameCapturedMicros: UInt64? = nil,
        frameDispatchedMicros: UInt64? = nil,
        pacer: MobileTerminalPacerSample? = nil
    ) {
        self.inputReceivedMicros = inputReceivedMicros
        self.inputAcceptedMicros = inputAcceptedMicros
        self.frameCapturedMicros = frameCapturedMicros
        self.frameDispatchedMicros = frameDispatchedMicros
        self.pacer = pacer
    }

    enum CodingKeys: String, CodingKey {
        case inputReceivedMicros = "input_received_us"
        case inputAcceptedMicros = "input_accepted_us"
        case frameCapturedMicros = "frame_captured_us"
        case frameDispatchedMicros = "frame_dispatched_us"
        case pacer
    }

    /// Whether the input stamps describe one complete, ordered Mac pass.
    public var hasCompleteInputStamps: Bool {
        guard let received = inputReceivedMicros,
              let accepted = inputAcceptedMicros,
              let captured = frameCapturedMicros,
              let dispatched = frameDispatchedMicros else { return false }
        return received <= accepted && accepted <= captured && captured <= dispatched
    }
}

/// The emission pacer's state for one surface over one sampling interval.
public struct MobileTerminalPacerSample: Codable, Equatable, Sendable {
    /// The pacing period in effect when sampled, in milliseconds.
    public var periodMillis: Int
    /// Frames emitted since the previous sample.
    public var emitted: Int
    /// Updates coalesced (not captured) since the previous sample.
    public var coalesced: Int
    /// Transport shed events that widened the period since the previous sample.
    public var sheds: Int

    public init(periodMillis: Int, emitted: Int, coalesced: Int, sheds: Int) {
        self.periodMillis = periodMillis
        self.emitted = emitted
        self.coalesced = coalesced
        self.sheds = sheds
    }

    enum CodingKeys: String, CodingKey {
        case periodMillis = "period_ms"
        case emitted
        case coalesced
        case sheds
    }
}

/// Splits a keystroke's network time into uplink and downlink across two
/// unsynchronized monotonic clocks.
///
/// One sample is the four NTP timestamps: phone send `t1`, Mac receive `t2`,
/// Mac dispatch `t3`, phone receive `t4`. The round trip spent on the network
/// is exact without any clock sync: `(t4 - t1) - (t3 - t2)`. Splitting it
/// needs the clock offset, which is estimated from the sample with the
/// smallest network round trip seen so far: queueing inflates delay, so the
/// quickest exchange is the one whose paths were closest to symmetric. The
/// split is an estimate; the round trip is not.
public struct MobileTerminalClockOffsetEstimator: Sendable {
    /// Estimated (Mac clock - phone clock), in nanoseconds.
    public private(set) var offsetNanos: Int64?
    private var bestRoundTripNanos: UInt64?

    public init() {}

    /// Network time for one exchange, in nanoseconds.
    public struct Split: Equatable, Sendable {
        public let roundTripNanos: UInt64
        public let uplinkNanos: UInt64
        public let downlinkNanos: UInt64
    }

    /// Records one exchange and returns its network split, or nil when the
    /// timestamps are inconsistent. Phone times are nanoseconds; Mac times are
    /// microseconds, as carried on the wire.
    public mutating func observe(
        phoneSendNanos t1: UInt64,
        macReceiveMicros: UInt64,
        macDispatchMicros: UInt64,
        phoneReceiveNanos t4: UInt64
    ) -> Split? {
        let t2 = macReceiveMicros &* 1_000
        let t3 = macDispatchMicros &* 1_000
        guard t4 >= t1, t3 >= t2 else { return nil }
        let total = t4 - t1
        let hostTime = t3 - t2
        guard total >= hostTime else { return nil }
        let roundTrip = total - hostTime
        let sampleOffset = (Int64(bitPattern: t2 &- t1) &+ Int64(bitPattern: t3 &- t4)) / 2
        if bestRoundTripNanos.map({ roundTrip < $0 }) ?? true {
            bestRoundTripNanos = roundTrip
            offsetNanos = sampleOffset
        }
        let offset = offsetNanos ?? sampleOffset
        let uplink = Int64(bitPattern: t2 &- t1) &- offset
        let clampedUplink = UInt64(max(0, min(Int64(roundTrip), uplink)))
        return Split(
            roundTripNanos: roundTrip,
            uplinkNanos: clampedUplink,
            downlinkNanos: roundTrip - clampedUplink
        )
    }

    /// Forget the offset, for a new connection or Mac.
    public mutating func reset() {
        offsetNanos = nil
        bestRoundTripNanos = nil
    }
}

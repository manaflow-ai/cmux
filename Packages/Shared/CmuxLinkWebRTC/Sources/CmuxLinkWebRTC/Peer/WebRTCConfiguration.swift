public import CmuxLink

/// Timeouts and buffer limits of the WebRTC carrier (b2-webrtc.md
/// sections 6 and 7). Every delay runs on `clock`.
public struct WebRTCConfiguration: Sendable {
    /// From the offer to an open control channel.
    public var connectTimeout: Duration
    /// An ICE restart that does not reach `connected` by then ends the transport.
    public var iceRestartTimeout: Duration
    /// How long ICE may sit in `disconnected` before the dialer restarts it.
    public var disconnectedGrace: Duration
    /// How long a graceful close waits for the peer's `fin.ack`.
    public var closeTimeout: Duration
    /// How often a live connection refreshes the selected ICE pair RTT.
    /// `nil` disables steady-state sampling while retaining connect and ICE
    /// transition samples. This is telemetry, not a synchronization clock.
    public var rttSampleInterval: Duration?
    /// A data channel takes another message only while its buffered bytes
    /// are at or below this (lanes and the datagram channel).
    public var highWaterBytes: UInt64
    /// Datagram `send` resumes once the buffer falls to this.
    public var lowWaterBytes: UInt64
    /// Largest data channel message; lane frames are split into pieces of
    /// this size (d2-bakeoff.md F1). 8 KiB keeps SCTP bursts below what a
    /// receiving UDP socket absorbs.
    public var maxMessageBytes: Int
    /// Bytes one lane may queue in the carrier: `send` suspends past it on
    /// reliable lanes and drops on unordered and partial lanes.
    public var laneBudgetBytes: Int
    /// Reliable lane bytes in flight (sent, not yet credited by the peer).
    /// SCTP on its own lets the window grow to the peer's 5 MiB receive
    /// window and bursts past a UDP socket buffer (786 KiB by default on
    /// macOS); dcSCTP's recovery from that burst loss stalls every lane
    /// (d2-bakeoff.md F1). 512 KiB is 80 Mbit/s at 50 ms RTT.
    public var inFlightWindowBytes: Int
    public var network: WebRTCNetworkMode
    public var clock: LinkClock

    public init(
        connectTimeout: Duration = .seconds(15),
        iceRestartTimeout: Duration = .seconds(10),
        disconnectedGrace: Duration = .seconds(2),
        closeTimeout: Duration = .seconds(2),
        rttSampleInterval: Duration? = .seconds(1),
        highWaterBytes: UInt64 = 128 << 10,
        lowWaterBytes: UInt64 = 32 << 10,
        maxMessageBytes: Int = 8 << 10,
        laneBudgetBytes: Int = 1 << 20,
        inFlightWindowBytes: Int = 256 << 10,
        network: WebRTCNetworkMode = .standard,
        clock: LinkClock = .continuous
    ) {
        self.connectTimeout = connectTimeout
        self.iceRestartTimeout = iceRestartTimeout
        self.disconnectedGrace = disconnectedGrace
        self.closeTimeout = closeTimeout
        self.rttSampleInterval = rttSampleInterval
        self.highWaterBytes = highWaterBytes
        self.lowWaterBytes = lowWaterBytes
        self.maxMessageBytes = maxMessageBytes
        self.laneBudgetBytes = laneBudgetBytes
        self.inFlightWindowBytes = inFlightWindowBytes
        self.network = network
        self.clock = clock
    }
}

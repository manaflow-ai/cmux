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
    /// `send` suspends above this many buffered bytes per data channel.
    public var highWaterBytes: UInt64
    /// ...and resumes below this.
    public var lowWaterBytes: UInt64
    public var network: WebRTCNetworkMode
    public var clock: LinkClock

    public init(
        connectTimeout: Duration = .seconds(15),
        iceRestartTimeout: Duration = .seconds(10),
        disconnectedGrace: Duration = .seconds(2),
        closeTimeout: Duration = .seconds(2),
        highWaterBytes: UInt64 = 1 << 20,
        lowWaterBytes: UInt64 = 256 << 10,
        network: WebRTCNetworkMode = .standard,
        clock: LinkClock = .continuous
    ) {
        self.connectTimeout = connectTimeout
        self.iceRestartTimeout = iceRestartTimeout
        self.disconnectedGrace = disconnectedGrace
        self.closeTimeout = closeTimeout
        self.highWaterBytes = highWaterBytes
        self.lowWaterBytes = lowWaterBytes
        self.network = network
        self.clock = clock
    }
}

/// Tunables of the V2 carrier. Defaults follow b3-webrtc-wg.md.
public struct WireGuardLinkConfiguration: Sendable, Hashable {
    /// WireGuard timers. `rekeyTimeout` defaults to 1 s instead of the
    /// protocol's 5 s: it is this end's own handshake retry cadence (the
    /// first-connect watchdog of transport.md 12b), not a wire constant.
    public var timers: WireGuardTimers
    /// How long `connect` (and a host's pending handshake) may take.
    public var connectTimeout: Duration
    /// Unacknowledged bytes per reliable lane before `send` suspends.
    public var reliableWindowBytes: Int
    /// Queued datagrams per unordered or partial lane before the oldest drops.
    public var messageQueueLimit: Int
    public var minimumRetransmitTimeout: Duration
    public var maximumRetransmitTimeout: Duration
    /// After an underlay dies, how long the session waits for a new one.
    public var rebindWindow: Duration
    /// A fragment unacknowledged this long means the path is dead.
    public var deadPathTimeout: Duration
    /// How long a graceful close waits for acks before it gives up.
    public var closeTimeout: Duration
    public var maxFrameBytes: Int

    public init(
        timers: WireGuardTimers = WireGuardTimers(rekeyTimeout: .seconds(1)),
        connectTimeout: Duration = .seconds(10),
        reliableWindowBytes: Int = 1024 * 1024,
        messageQueueLimit: Int = 512,
        minimumRetransmitTimeout: Duration = .milliseconds(50),
        maximumRetransmitTimeout: Duration = .seconds(2),
        rebindWindow: Duration = .seconds(10),
        deadPathTimeout: Duration = .seconds(20),
        closeTimeout: Duration = .seconds(2),
        maxFrameBytes: Int = 256 * 1024
    ) {
        self.timers = timers
        self.connectTimeout = connectTimeout
        self.reliableWindowBytes = reliableWindowBytes
        self.messageQueueLimit = messageQueueLimit
        self.minimumRetransmitTimeout = minimumRetransmitTimeout
        self.maximumRetransmitTimeout = maximumRetransmitTimeout
        self.rebindWindow = rebindWindow
        self.deadPathTimeout = deadPathTimeout
        self.closeTimeout = closeTimeout
        self.maxFrameBytes = maxFrameBytes
    }
}

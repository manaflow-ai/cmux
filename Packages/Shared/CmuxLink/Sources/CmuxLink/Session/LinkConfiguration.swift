/// Timeouts and limits of a `LinkSession` or `LinkHost`.
public struct LinkConfiguration: Sendable, Hashable {
    /// Dialer: how long a new transport may take to answer `hello`.
    public var handshakeTimeout: Duration
    public var backoff: Backoff
    /// Dialer: consecutive failed attempts before `closed(.unreachable)`.
    public var maxConnectAttempts: Int
    /// Host: how long a session waits for its dialer to resume.
    public var resumeWindow: Duration
    /// Largest encoded frame regardless of path.
    public var maxFrameBytes: Int
    /// Maximum channels retained in one link session. Incoming opens past this
    /// limit are refused with a channel close instead of growing the session
    /// table indefinitely.
    public var maxChannels: Int
    /// Maximum incoming handles retained before a feature subscribes. A peer
    /// can publish channels/tracks before the app starts its consumer; these
    /// queues stay bounded independently of transport credit.
    public var maxPendingIncomingChannels: Int
    public var maxPendingIncomingMediaTracks: Int
    /// Maximum newly accepted sessions retained before `LinkHost.sessions()`
    /// has a consumer.
    public var maxPendingSessions: Int
    /// Smoothed RTT above this marks the link degraded. `nil` disables.
    public var degradedRTT: Duration?

    public init(
        handshakeTimeout: Duration = .seconds(5),
        backoff: Backoff = Backoff(),
        maxConnectAttempts: Int = 8,
        resumeWindow: Duration = .seconds(600),
        maxFrameBytes: Int = 256 * 1024,
        maxChannels: Int = 256,
        maxPendingIncomingChannels: Int = 64,
        maxPendingIncomingMediaTracks: Int = 16,
        maxPendingSessions: Int = 64,
        degradedRTT: Duration? = .milliseconds(300)
    ) {
        self.handshakeTimeout = handshakeTimeout
        self.backoff = backoff
        self.maxConnectAttempts = max(1, maxConnectAttempts)
        self.resumeWindow = resumeWindow
        self.maxFrameBytes = max(1, maxFrameBytes)
        self.maxChannels = max(1, maxChannels)
        self.maxPendingIncomingChannels = max(1, maxPendingIncomingChannels)
        self.maxPendingIncomingMediaTracks = max(1, maxPendingIncomingMediaTracks)
        self.maxPendingSessions = max(1, maxPendingSessions)
        self.degradedRTT = degradedRTT
    }
}

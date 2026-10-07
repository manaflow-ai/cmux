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
    /// Smoothed RTT above this marks the link degraded. `nil` disables.
    public var degradedRTT: Duration?

    public init(
        handshakeTimeout: Duration = .seconds(5),
        backoff: Backoff = Backoff(),
        maxConnectAttempts: Int = 8,
        resumeWindow: Duration = .seconds(600),
        maxFrameBytes: Int = 256 * 1024,
        degradedRTT: Duration? = .milliseconds(300)
    ) {
        self.handshakeTimeout = handshakeTimeout
        self.backoff = backoff
        self.maxConnectAttempts = max(1, maxConnectAttempts)
        self.resumeWindow = resumeWindow
        self.maxFrameBytes = maxFrameBytes
        self.degradedRTT = degradedRTT
    }
}

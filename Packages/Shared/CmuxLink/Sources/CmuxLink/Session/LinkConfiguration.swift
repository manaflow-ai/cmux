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
    /// Target bytes per second used to size the default terminal render credit
    /// from the current path RTT. `nil` keeps the fixed 256 KiB window.
    /// Non-default channel budgets are never changed by this setting.
    public var renderCreditTargetBytesPerSecond: Int?
    /// Upper bound for the RTT-sized default render credit.
    public var maxRenderCreditBytes: Int

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
        degradedRTT: Duration? = .milliseconds(300),
        renderCreditTargetBytesPerSecond: Int? = 2_500_000,
        maxRenderCreditBytes: Int = 2 * 1024 * 1024
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
        if let renderCreditTargetBytesPerSecond {
            self.renderCreditTargetBytesPerSecond = max(1, renderCreditTargetBytesPerSecond)
        } else {
            self.renderCreditTargetBytesPerSecond = nil
        }
        self.maxRenderCreditBytes = max(1, maxRenderCreditBytes)
    }

    /// Returns the bounded credit for the default reliable render channel.
    /// A path with no RTT sample keeps the protocol's 256 KiB baseline.
    /// `base` is accepted for callers that use a different default; channel
    /// descriptors with a non-default budget bypass this helper in
    /// `LinkSession`.
    public func renderCreditBudget(for rtt: Duration?, base: Int = ChannelDescriptor.defaultBudget(for: .render)) -> Int {
        let base = max(1, base)
        guard let rtt, let target = renderCreditTargetBytesPerSecond else { return base }
        let components = rtt.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
        guard seconds.isFinite, seconds > 0 else { return base }
        let cap = max(base, maxRenderCreditBytes)
        let estimate = (seconds * Double(target)).rounded(.up)
        // Duration is caller supplied and can be far larger than any network
        // RTT. Clamp in floating point before converting so pathological input
        // cannot trap the process on an overflowing `Int` conversion.
        guard estimate < Double(Int.max) else { return cap }
        return min(max(base, Int(estimate)), cap)
    }
}

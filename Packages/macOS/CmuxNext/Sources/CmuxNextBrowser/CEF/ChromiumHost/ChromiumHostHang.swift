/// A hang of the Chromium Host's UI thread, as the host measured it (`kOpHostHang`,
/// ChromiumHost/src/host_hang_watcher.h): one run loop turn of 250 ms or more.
public nonisolated struct ChromiumHostHang: Equatable, Sendable {
    /// How long the turn ran (so far, when ``isOngoing``).
    public var duration: Duration
    /// The turn still ran: the watcher's report at its 10 s dump.
    public var isOngoing: Bool
    /// The host wrote a dump of it without crashing.
    public var dumped: Bool
    /// The turn's end of a hang the host already reported while it ran (the watcher's ``isOngoing`` report).
    public var wasReported: Bool

    public init(duration: Duration, isOngoing: Bool, dumped: Bool, wasReported: Bool = false) {
        self.duration = duration
        self.isOngoing = isOngoing
        self.dumped = dumped
        self.wasReported = wasReported
    }

    /// A hang report takes each hang once: the host's first report of it, the watcher's while it runs or
    /// else its end. The host says which (it alone knows whether its watcher reported the turn), so a hang
    /// the watcher missed (no watcher thread, or the turn ended before the late watcher looked) still counts.
    public var isFirstReport: Bool { isOngoing || !wasReported }

    /// `kOpHostHang`'s flags (host_hang_watcher.h): 1 still running, 2 dumped, 4 already reported.
    init(durationNanos: Int64, flags: Int64) {
        self.init(duration: .nanoseconds(max(durationNanos, 0)), isOngoing: flags & 1 != 0, dumped: flags & 2 != 0,
                  wasReported: flags & 4 != 0)
    }
}

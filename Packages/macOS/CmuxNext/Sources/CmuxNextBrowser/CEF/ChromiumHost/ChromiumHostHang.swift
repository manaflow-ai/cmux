/// A hang of the Chromium Host's UI thread, as the host measured it (`kOpHostHang`,
/// ChromiumHost/src/host_hang_watcher.h): one run loop turn of 250 ms or more.
public nonisolated struct ChromiumHostHang: Equatable, Sendable {
    /// How long the turn ran (so far, when ``isOngoing``).
    public var duration: Duration
    /// The turn still ran: the watcher's report at its 10 s dump.
    public var isOngoing: Bool
    /// The host wrote a dump of it without crashing.
    public var dumped: Bool

    public init(duration: Duration, isOngoing: Bool, dumped: Bool) {
        self.duration = duration
        self.isOngoing = isOngoing
        self.dumped = dumped
    }

    /// The host's watcher dumps a turn this old and reports it then, still running (`Limits::dump_ns`,
    /// host_hang_watcher.h; Chrome's `kDefaultHangWatchTime`).
    public static let dumpAfter: Duration = .seconds(10)

    /// The host reports a turn that reaches ``dumpAfter`` twice, at the dump and at its end: a hang report
    /// takes it once, at the dump, which comes even when the person then reloads the host.
    public var isFirstReport: Bool { isOngoing || duration < Self.dumpAfter }

    /// `kOpHostHang`'s flags (host_hang_watcher.h): 1 still running, 2 dumped.
    init(durationNanos: Int64, flags: Int64) {
        self.init(duration: .nanoseconds(max(durationNanos, 0)), isOngoing: flags & 1 != 0, dumped: flags & 2 != 0)
    }
}

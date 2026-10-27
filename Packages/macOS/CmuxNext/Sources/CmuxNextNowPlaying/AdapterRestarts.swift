import CmuxNextTrace

/// When the Now Playing stream (``MediaRemoteAdapterProcess``) starts again: after a wait that doubles with
/// each quick exit in a row (an exit less than ``quickExitNanos`` after its start), and never after more than
/// ``maximumQuickExits`` in a row (an adapter macOS no longer allows).
///
/// A run is timed on the trace clock (``TraceClock``), which stops while the Mac sleeps: a run's length is the
/// time the stream had to run. A stream that ran 2 s, slept with the Mac and ended on wake counts as quick;
/// one quick exit only doubles the next wait, and a stream that then runs 10 s clears the count.
nonisolated struct AdapterRestarts: Sendable {
    static let quickExitNanos: UInt64 = 10_000_000_000
    static let maximumQuickExits = 4
    /// The longest wait before a start: 2^6 s.
    static let maximumWaitExponent = 6

    let clock: TraceClock
    private var startedNanos: UInt64 = 0
    /// Exits in a row that came soon after their start.
    private(set) var quickExits = 0

    init(clock: TraceClock) {
        self.clock = clock
    }

    /// A new ``SystemNowPlayingAdapter/start(onUpdate:)``: no quick exits so far.
    mutating func reset() {
        quickExits = 0
    }

    /// A stream starts now.
    mutating func started() {
        startedNanos = clock.nowNanos()
    }

    /// The stream that last ``started()`` ended at `endedNanos` (``TraceClock/nowNanos()``): the wait before it
    /// starts again, or nil to give up.
    mutating func exited(atNanos endedNanos: UInt64) -> Duration? {
        quickExits = endedNanos &- startedNanos < Self.quickExitNanos ? quickExits + 1 : 0
        guard quickExits <= Self.maximumQuickExits else { return nil }
        return .seconds(1 << min(quickExits, Self.maximumWaitExponent))
    }
}

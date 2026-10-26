import Darwin
import CmuxNextCompat
public import CmuxNextWakeups

/// Turns the main-thread watchdog's hang episodes into Sentry app-hang events,
/// at most one per episode: the process has one hang watcher, as Chrome has
/// one `HangWatcher` per process (`base/threading/hang_watcher.h`), and the
/// SDK's own ANR thread is off.
///
/// The watchdog reports a hang once per stall at its hang threshold, on its
/// own thread, with the main thread's stack (``noteHang(duration:addresses:otherThreads:)``),
/// and every finished stall on the main thread (``noteStall(startUptimeNanos:duration:)``).
/// An episode still blocked at ``threshold`` (8 s, the SDK's former
/// `appHangTimeoutInterval`) sends one ongoing event then, so a hang the
/// person ends by force-quitting is still reported; an episode that ends
/// past ``threshold`` before that deadline fires sends one event with its
/// exact duration. A shorter episode sends nothing here (its stall is a lag
/// spike, ``LagSpikeReporter``).
///
/// The deadline is one ``DemandTimer`` armed only while a hang runs, so an
/// app with no hang has no timer.
public final class AppHangReporter: Sendable {
    /// The sink an episode's event goes to (crash reporting in the app; a
    /// recorder in tests). Called off the main thread.
    public typealias Sink = @Sendable (AppHangEvent) -> Void

    /// An episode is an app hang once the main thread is blocked this long.
    public let threshold: Duration
    private let isEnabled: @Sendable () -> Bool
    private let sink: Sink
    private let deadline: DemandTimer
    private let uptime: @Sendable () -> UInt64
    // Lock carve-out: one synchronous check of a few fields from the watchdog
    // thread (a hang began) and from the main thread at each stall end; an
    // actor hop would add a Task per main-thread stall.
    private let state = Mutex(State())

    private struct Episode {
        var id: UInt64
        /// `CLOCK_UPTIME_RAW` nanoseconds when the main thread stopped answering, or a little after.
        var startNanos: UInt64
        var addresses: [UInt]
        var otherThreads: [(name: String, addresses: [UInt])]
    }

    private struct State {
        var lastID: UInt64 = 0
        var open: Episode?
        /// When the newest finished stall ended (`CLOCK_UPTIME_RAW` nanoseconds).
        var lastStallEndNanos: UInt64 = 0
    }

    /// Reports to `reporter` while it runs.
    public convenience init(reporter: CrashReporter) {
        self.init(threshold: CrashReporter.appHangThreshold, isEnabled: { reporter.isStarted },
                  sink: { event in Task.detached(priority: .utility) { reporter.reportAppHang(event) } },
                  deadline: DemandTimer(owner: "crash-reporting.app-hang-deadline"))
    }

    /// Test seam: the threshold, enabled check, sink, deadline timer and the
    /// watchdog's monotonic clock.
    public init(threshold: Duration, isEnabled: @escaping @Sendable () -> Bool, sink: @escaping Sink, deadline: DemandTimer,
                uptime: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }) {
        self.threshold = threshold
        self.isEnabled = isEnabled
        self.sink = sink
        self.deadline = deadline
        self.uptime = uptime
    }

    /// The watchdog's hang report (watchdog thread, once per stall): the main
    /// thread has been blocked for `duration`, with its stack `addresses`.
    public func noteHang(duration: Duration, addresses: [UInt], otherThreads: [(name: String, addresses: [UInt])] = []) {
        guard isEnabled() else { return }
        let elapsed = Self.nanos(duration)
        let now = uptime()
        let start = now > elapsed ? now - elapsed : 0
        let id: UInt64? = state.withLock { state in
            // A stall that ended after this hang began is this hang: the main thread answered
            // before the report reached here, so the episode is over.
            guard state.lastStallEndNanos <= start else { return nil }
            state.lastID &+= 1
            state.open = Episode(id: state.lastID, startNanos: start, addresses: addresses, otherThreads: otherThreads)
            return state.lastID
        }
        guard let id else { return }
        let remaining = threshold - duration
        deadline.schedule(after: max(remaining, .zero)) { [weak self] in self?.deadlineReached(id) }
    }

    /// A finished main-thread stall (main thread, from the watchdog's `onStall`).
    /// Must return at once: no event is built here.
    public func noteStall(startUptimeNanos: UInt64, duration: Duration) {
        let end = startUptimeNanos &+ Self.nanos(duration)
        let ended: Episode? = state.withLock { state in
            state.lastStallEndNanos = max(state.lastStallEndNanos, end)
            guard let open = state.open, end > open.startNanos else { return nil }
            state.open = nil
            return open
        }
        guard let ended else { return }
        deadline.cancel()
        guard duration >= threshold else { return }
        sink(AppHangEvent(duration: duration, ongoing: false, addresses: ended.addresses, otherThreads: ended.otherThreads))
    }

    /// The episode `id` is still blocked at ``threshold``.
    private func deadlineReached(_ id: UInt64) {
        let episode: Episode? = state.withLock { state in
            guard let open = state.open, open.id == id else { return nil }
            state.open = nil
            return open
        }
        guard let episode else { return }
        sink(AppHangEvent(duration: threshold, ongoing: true, addresses: episode.addresses, otherThreads: episode.otherThreads))
    }

    private static func nanos(_ duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        return UInt64(clamping: max(Int64(0), seconds)) &* 1_000_000_000 &+ UInt64(clamping: max(Int64(0), attoseconds / 1_000_000_000))
    }
}

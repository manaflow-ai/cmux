import CmuxNextCompat
import CmuxNextMetrics

/// The main thread's field histograms (plans/cmux-next/chrome-parity/p09-observability.md section 3D, task 055),
/// fed by ``MainThreadWatchdog``'s heartbeat on the main thread with the stamps it already took: no observer,
/// timer or clock read of its own.
///
/// - `main.turn`: each run-loop turn's busy time, wake to sleep, in us.
/// - `hang.over250.per_hour`: one sample per active hour, the stalls of 250 ms or more that ended in it.
///
/// Active time is every turn's busy time plus the idle gap before it, a gap counting at most 5 minutes: Chrome
/// ends a desktop session after 5 minutes with no activity
/// (chrome/browser/metrics/desktop_session_duration/desktop_session_duration_tracker.cc), so an app left idle
/// overnight adds 5 minutes, not 8 hours, to the rate's denominator. An idle app's main thread does not wake,
/// so a wake is activity. The partial hour a launch ends in is not recorded.
///
/// One writer, the main thread: the counters are relaxed atomics only so that the class is `Sendable`.
final class MainThreadFieldMetrics: Sendable {
    /// The longest idle gap active time counts.
    static let idleCapNanos: UInt64 = 5 * 60 * 1_000_000_000
    /// The active time of one `hang.over250.per_hour` sample.
    static let activeHourNanos: UInt64 = 3_600 * 1_000_000_000

    private let metrics: Metrics
    /// Active time since the last full active hour.
    private let activeNanos = Atomic<UInt64>(0)
    /// The end of the last turn, 0 before the first.
    private let lastTurnEndNanos = Atomic<UInt64>(0)
    /// Stalls of 250 ms or more since the last full active hour.
    private let hourStalls = Atomic<UInt64>(0)

    /// Records into `metrics` (the app runtime's store by default; tests pass their own).
    init(metrics: Metrics = Metrics()) {
        self.metrics = metrics
    }

    /// A main-thread work gap of 250 ms or more ended (the heartbeat's `count250` edge).
    func stallOver250Ended() {
        hourStalls.wrappingAdd(1, ordering: .relaxed)
    }

    /// A turn ended: records its busy time and adds it and the capped idle gap before it to the active time,
    /// recording one rate sample per full active hour (the first gets the stalls, any more of one long turn 0).
    // perf-hot: 1us frame-tick
    func turnEnded(start: UInt64, end: UInt64) {
        let busy = end - start
        metrics.record(.mainTurn, Int64(clamping: busy / 1_000))
        let previousEnd = lastTurnEndNanos.load(ordering: .relaxed)
        lastTurnEndNanos.store(end, ordering: .relaxed)
        let idle = previousEnd > 0 && start > previousEnd ? min(start - previousEnd, Self.idleCapNanos) : 0
        var active = activeNanos.load(ordering: .relaxed).saturatingAddition(idle).saturatingAddition(busy)
        while active >= Self.activeHourNanos {
            let stalls = hourStalls.exchange(0, ordering: .relaxed)
            metrics.record(.hangOver250PerHour, Int64(clamping: stalls))
            active -= Self.activeHourNanos
        }
        activeNanos.store(active, ordering: .relaxed)
    }
}

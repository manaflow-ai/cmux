import CmuxNextCompat
import CmuxNextMetrics

/// The main thread's field histograms (plans/cmux-next/chrome-parity/p09-observability.md section 3D, task 055),
/// fed by ``MainThreadWatchdog`` on the main thread with the stamps it already took: no observer, timer or clock
/// read of its own.
///
/// - `main.turn`: each run-loop turn's busy time, wake to sleep, in us.
/// - `hang.over250.per_hour`: one sample per 30 s of active time, that interval's stalls of 250 ms or more as a
///   rate per hour (stalls × 120), so the histogram's mean is stalls per active hour. A short interval, as
///   Chrome's responsiveness calculator measures 30 s intervals (content/browser/scheduler/responsiveness/
///   calculator.cc), keeps what a crash or force quit loses under 30 active seconds; a decided quit records the
///   open interval (``recordOpenInterval()``).
///
/// Active time follows the person, not the main thread's wakes (an idle app still wakes several times a second):
/// the time between two input events counts when they are under 5 minutes apart, as Chrome's desktop session ends
/// 5 minutes after the last user event and does not count those 5 minutes
/// (chrome/browser/metrics/desktop_session_duration/desktop_session_duration_tracker.cc). A stall counts when it
/// starts less than 5 minutes after the newest input.
///
/// - `hang.thread_hung.<lane>`: the same intervals, each lane's hangs in it as a rate per hour (hangs × 120),
///   counted by the watchdog thread (the main thread's own 2 s hangs, the hang monitor's lanes). Only a lane that
///   hung records a sample, so idle lanes add nothing to an upload: a lane's hangs per active hour are its sum over
///   the sample count of `hang.over250.per_hour`, which records every interval (Chrome records
///   `HangWatcher.IsThreadHung.*` per monitoring period, base/threading/hang_watcher.cc).
///
/// One writer, the main thread, apart from the lane hang counts the watchdog thread adds: the counters are relaxed
/// atomics.
final class MainThreadFieldMetrics: Sendable {
    /// Two inputs further apart than this end the session between them: the gap is not active time.
    static let inactivityNanos: UInt64 = 5 * 60 * 1_000_000_000
    /// The active time of one `hang.over250.per_hour` sample.
    static let intervalNanos: UInt64 = 30 * 1_000_000_000
    /// An interval's stall count times this is its rate per hour.
    static let intervalsPerHour: UInt64 = 3_600 * 1_000_000_000 / intervalNanos

    private let metrics: Metrics
    /// The newest input event's time (ns of uptime), 0 before the first.
    private let lastInputNanos = Atomic<UInt64>(0)
    /// Active time in the open interval.
    private let intervalActiveNanos = Atomic<UInt64>(0)
    /// Stalls of 250 ms or more in the open interval.
    private let intervalStalls = Atomic<UInt64>(0)
    /// Hangs per lane in the open interval: lane `i` of `HistogramID.HangLane.allCases` is byte `i % 8` of word
    /// `i / 8`, saturating at 255. The watchdog thread adds, the main thread takes each word whole.
    private let laneHangs0 = Atomic<UInt64>(0), laneHangs1 = Atomic<UInt64>(0), laneHangs2 = Atomic<UInt64>(0)
    /// How many lanes the counts hold (a lane past them counts as `other`).
    static let laneCapacity = laneWords * lanesPerWord
    private static let laneWords = 3, lanesPerWord = 8

    /// Records into `metrics` (the app runtime's store by default; tests pass their own).
    init(metrics: Metrics = Metrics()) {
        self.metrics = metrics
    }

    /// A turn ended: records its busy time as `main.turn`.
    // perf-hot: 1us frame-tick
    func turnEnded(start: UInt64, end: UInt64) {
        metrics.record(.mainTurn, Int64(clamping: (end - start) / 1_000))
    }

    /// The person's input event at `nanos` (its OS time, ns of uptime; newer than any before) was dispatched: the
    /// time since the previous input is active time when under 5 minutes, and each full interval records a sample
    /// (the first gets the open interval's stalls, any more of one long gap 0).
    // perf-hot: 1us frame-tick
    func inputArrived(atNanos nanos: UInt64) {
        let previous = lastInputNanos.load(ordering: .relaxed)
        lastInputNanos.store(nanos, ordering: .relaxed)
        guard previous > 0, nanos > previous, nanos - previous < Self.inactivityNanos else { return }
        var active = intervalActiveNanos.load(ordering: .relaxed) + (nanos - previous)
        while active >= Self.intervalNanos {
            recordInterval()
            active -= Self.intervalNanos
        }
        intervalActiveNanos.store(active, ordering: .relaxed)
    }

    /// A main-thread work gap of 250 ms or more that began at `start` ended (the heartbeat's `count250` edge). It
    /// counts when the person was active then: under 5 minutes after the newest input, or before it.
    func stallOver250Ended(start: UInt64) {
        let input = lastInputNanos.load(ordering: .relaxed)
        guard input > 0, start < input || start - input < Self.inactivityNanos else { return }
        intervalStalls.wrappingAdd(1, ordering: .relaxed)
    }

    /// A hang of `lane` that began at `atNanos` (ns of uptime: a lane's budget end, the main thread's stall start) was
    /// reported (watchdog thread). It counts when the person was active then, as a stall does.
    func threadHung(_ lane: HistogramID.HangLane, atNanos: UInt64) {
        let input = lastInputNanos.load(ordering: .relaxed)
        guard input > 0, atNanos < input || atNanos - input < Self.inactivityNanos else { return }
        let index = Self.laneIndex(lane)
        let shift = index % Self.lanesPerWord * 8
        withLaneWord(index / Self.lanesPerWord) { word in
            var current = word.load(ordering: .relaxed)
            while current >> shift & 0xFF < 0xFF {
                let (exchanged, original) = word.compareExchange(expected: current, desired: current &+ 1 << shift, ordering: .relaxed)
                if exchanged { break }
                current = original
            }
        }
    }

    /// Records the open interval as a full one when it has active time, stalls or lane hangs (a decided quit: its
    /// stalls and hangs are not lost, and the active time is overstated by under one interval).
    func recordOpenInterval() {
        let active = intervalActiveNanos.exchange(0, ordering: .relaxed)
        guard active > 0 || intervalStalls.load(ordering: .relaxed) > 0 || hasLaneHangs else { return }
        recordInterval()
    }

    /// One `hang.over250.per_hour` sample: the open interval's stalls as a rate per hour, and one
    /// `hang.thread_hung.<lane>` sample per lane that hung in it; the counts start again.
    private func recordInterval() {
        let stalls = intervalStalls.exchange(0, ordering: .relaxed)
        metrics.record(.hangOver250PerHour, Int64(clamping: stalls.saturatingMultiplication(Self.intervalsPerHour)))
        var lanes = HistogramID.HangLane.allCases.makeIterator()
        for wordIndex in 0 ..< Self.laneWords {
            var counts = withLaneWord(wordIndex) { word in word.exchange(0, ordering: .relaxed) }
            for _ in 0 ..< Self.lanesPerWord {
                guard let lane = lanes.next() else { break }
                let hangs = counts & 0xFF
                if hangs > 0 { metrics.record(.hangThreadHung(lane), Int64(clamping: hangs * Self.intervalsPerHour)) }
                counts >>= 8
            }
        }
    }

    /// Lane `lane`'s place in the counts: its place in `allCases`, or `other`'s past `laneCapacity`.
    private static func laneIndex(_ lane: HistogramID.HangLane) -> Int {
        let lanes = HistogramID.HangLane.allCases
        if let index = lanes.firstIndex(of: lane), index < laneCapacity { return index }
        return lanes.firstIndex(of: .other) ?? 0
    }

    /// Whether a lane hung in the open interval.
    private var hasLaneHangs: Bool {
        (0 ..< Self.laneWords).contains { index in withLaneWord(index) { word in word.load(ordering: .relaxed) != 0 } }
    }

    private func withLaneWord<Value>(_ index: Int, _ body: (borrowing Atomic<UInt64>) -> Value) -> Value {
        switch index {
        case 0: body(laneHangs0)
        case 1: body(laneHangs1)
        default: body(laneHangs2)
        }
    }
}

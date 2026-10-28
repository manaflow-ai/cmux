public import CmuxNextInputCore
import CmuxNextMetrics
import Foundation

/// Counters of the external message pump since `CefInitialize` (`debug.cef`
/// `pump`). Wakeups per second over an interval is the difference of
/// `workRuns` between two reads divided by the interval.
public nonisolated struct CEFPumpStats: Equatable, Sendable {
    /// `CefDoMessageLoopWork` calls.
    public var workRuns = 0
    /// `OnScheduleMessagePumpWork(0)` requests (and cmux's own "pump now").
    public var immediateRequests = 0
    /// `OnScheduleMessagePumpWork(delay > 0)` requests, and the fork's absolute run times
    /// (`cmux_on_schedule_delayed`).
    public var delayedRequests = 0
    /// Timer fires that arrived while `CefDoMessageLoopWork` was already
    /// running (a nested run loop) and were deferred.
    public var reentrantFires = 0
    /// `CefDoMessageLoopWork` calls that used the fork's whole time slice
    /// (``CEFPumpSchedule/timeSlice(forkAPI:)``: 2 ms from fork API 26,
    /// else 10 ms; the fork asks for "now" itself when work remains).
    public var longWorkRuns = 0
    /// Total time inside `CefDoMessageLoopWork`, in seconds.
    public var workSeconds: Double = 0
    /// Delayed requests from Chromium threads kept with no main wake, because the armed fire came
    /// first (``CEFPumpCrossThreadGate``); the main thread merges them at its next pass or re-arm.
    /// They are not in ``delayedRequests``.
    public var keptCrossThreadRequests = 0
    /// Timer fires held because a shown frame was late and the pump had run
    /// its one pass for that frame (`RenderStarvationGuard`); each runs after
    /// the late link's tick.
    public var lateFrameHolds = 0
    /// Passes that ran while a person's input was pending (``CEFPumpInputPolicy``): by the target of
    /// the dispatched input that released them, and those the one-refresh bound released. DC2 reads
    /// every bucket but `chromiumPage` as 0.
    public var passesWhileInputPending = PassesByTarget()
    /// Passes the input policy held until an input's dispatch ended (one per hold).
    public var deferredForInput = 0
    /// Due passes the frame deadline held for the next frame: less than 1 ms was left before the
    /// frame's commit (``CEFPumpFrameDeadline``).
    public var frameDeadlineWaits = 0
    /// Due passes the frame deadline held for a person's input turn, a layout plan's apply, or pending
    /// input after a pass that used its whole slice (at most one wait in a row).
    public var frameInputHolds = 0
    /// Each pass's main-thread time while the input policy runs.
    public var passTimes = InputLatencyHistogram()
    /// Passes for a delayed fire date that came before Chromium's task was due (``EarlyPassWatch``), so one
    /// delayed task cost a second main wake. On the whole-millisecond path CEF truncates each delay against
    /// a stale `recent_now`, and such a pass ends with a re-ask under 2 ms. On the fork's absolute run times
    /// the pass began before the run time it serves, or Chromium reported that run time,
    /// or an earlier one, again during the pass.
    public var earlyPasses = 0

    /// One pass's main-thread time at the 99th percentile in milliseconds, 0 before any pass.
    public var passMillisecondsP99: Double {
        passTimes.percentileNanos(0.99).map { Double($0) / 1_000_000 } ?? 0
    }

    public init() {}

    /// Counts one `CefDoMessageLoopWork` call of `elapsed` seconds and records it as one `cef.pump` sample in us
    /// (``HistogramID/cefPump``) into `metrics`, the field histograms of the process that runs the pump: the app's,
    /// as only the in-process pump calls this. In host mode the Chromium host runs the pump and writes the pump
    /// numbers into its own metrics file (p09-observability task 104).
    ///
    /// - Returns: Whether it used CEF's whole time slice (a ``longWorkRuns`` pass; `cef.pump` end `arg0` 1).
    mutating func recordWorkRun(elapsed: TimeInterval, timeSlice: TimeInterval = CEFPumpSchedule.timeSlice,
                                metrics: Metrics) -> Bool {
        let longRun = elapsed >= timeSlice
        workRuns += 1
        workSeconds += elapsed
        if longRun { longWorkRuns += 1 }
        metrics.record(.cefPump, Int64(max(0, elapsed) * 1e6))
        return longRun
    }

    /// Decides which passes count as ``earlyPasses``. Only a pass for a delayed fire date can be early,
    /// only CEF's own requests during the pass count (one after it is a Chromium thread's or cmux's), and
    /// a pass that used CEF's whole time slice is not early: the fork asks for "now" because work is left.
    ///
    /// - Whole milliseconds: CEF re-asked under ``earlyReask`` ms during the pass. The truncated delay
    ///   cannot say which task it is, so a near re-ask is the sign.
    /// - Absolute run times: the pass began before the run time it serves, or Chromium reported a run
    ///   time at or before it during the pass (the task was not due). A later run time is the next task,
    ///   however close, and a "now" is posted work, not this task.
    nonisolated struct EarlyPassWatch: Equatable, Sendable {
        /// The largest early re-ask (exclusive) on the whole-millisecond path, in ms.
        static let earlyReask: Int64 = 2

        /// The pump gets the fork's absolute run times (`cmux_shim_set_schedule_delayed` returned 1).
        let absoluteRunTimes: Bool
        /// The fire date the running pass serves; nil when it serves none.
        private var servedRunTime: TimeInterval?
        /// The running pass is early so far.
        private var early = false

        init(absoluteRunTimes: Bool = false) {
            self.absoluteRunTimes = absoluteRunTimes
        }

        /// `servedRunTime`: the fire date the pass serves (nil: none); `start`: the pass's clock reading.
        mutating func passBegan(serving servedRunTime: TimeInterval?, at start: TimeInterval) {
            self.servedRunTime = servedRunTime
            early = false
            if absoluteRunTimes, let servedRunTime, start < servedRunTime { early = true }
        }

        /// True when the pass that just ended was early.
        mutating func passEnded(usedWholeSlice: Bool) -> Bool {
            defer {
                servedRunTime = nil
                early = false
            }
            return servedRunTime != nil && early && !usedWholeSlice
        }

        /// A whole-millisecond CEF request made on the main thread (0 for "now").
        mutating func request(milliseconds: Int64) {
            guard !absoluteRunTimes, servedRunTime != nil, milliseconds < Self.earlyReask else { return }
            early = true
        }

        /// A fork run time CEF reported on the main thread (``CEFPumpSchedule/runTime(nanos:)``).
        mutating func request(runTime: TimeInterval) {
            guard absoluteRunTimes, let servedRunTime, runTime <= servedRunTime else { return }
            early = true
        }
    }

    /// Pass counts while input was pending, per input target.
    public nonisolated struct PassesByTarget: Equatable, Sendable {
        /// Indexed by `InputTarget.rawValue`.
        private var counts = [Int](repeating: 0, count: InputTarget.allCases.count)
        /// Passes the one-refresh bound released with input still pending: that input was not
        /// dispatched yet, so its target is unknown.
        public var boundExpired = 0

        public init() {}

        /// Passes released right after an input to `target` was dispatched, with more input pending.
        /// Only `chromiumPage` is expected: Chromium acks its input inside the pump.
        public subscript(target: InputTarget) -> Int {
            counts[Int(target.rawValue)]
        }

        /// The counts by target name (`terminal`, `chromiumPage`, ...) and `boundExpired`
        /// (`debug.cef`, `debug.input`).
        public var byName: [String: UInt64] {
            var names = ["boundExpired": UInt64(clamping: boundExpired)]
            for target in InputTarget.allCases {
                names[String(describing: target)] = UInt64(clamping: counts[Int(target.rawValue)])
            }
            return names
        }

        mutating func add(_ target: InputTarget) {
            counts[Int(target.rawValue)] += 1
        }
    }
}

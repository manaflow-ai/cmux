public import CmuxNextInputCore
import Foundation

/// Counters of the external message pump since `CefInitialize` (`debug.cef`
/// `pump`). Wakeups per second over an interval is the difference of
/// `workRuns` between two reads divided by the interval.
public nonisolated struct CEFPumpStats: Equatable, Sendable {
    /// `CefDoMessageLoopWork` calls.
    public var workRuns = 0
    /// `OnScheduleMessagePumpWork(0)` requests (and cmux's own "pump now").
    public var immediateRequests = 0
    /// `OnScheduleMessagePumpWork(delay > 0)` requests.
    public var delayedRequests = 0
    /// Timer fires that arrived while `CefDoMessageLoopWork` was already
    /// running (a nested run loop) and were deferred.
    public var reentrantFires = 0
    /// `CefDoMessageLoopWork` calls that used CEF's whole 10 ms time slice
    /// (the fork asks for "now" itself when work remains).
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
    /// Each pass's main-thread time while the input policy runs.
    public var passTimes = InputLatencyHistogram()
    /// Passes for a delayed fire date that CEF answered during the pass, on the main thread, with a
    /// request under 2 ms (``EarlyPassWatch``): the pass came before Chromium's task was due, because CEF
    /// truncates each delay to whole milliseconds against a stale `recent_now` (the re-ask at the end of
    /// `CefDoMessageLoopWork`), so one delayed task cost a second main wake. 0 once the fork sends
    /// absolute run times (p14-energy-046).
    public var earlyPasses = 0

    /// One pass's main-thread time at the 99th percentile in milliseconds, 0 before any pass.
    public var passMillisecondsP99: Double {
        passTimes.percentileNanos(0.99).map { Double($0) / 1_000_000 } ?? 0
    }

    public init() {}

    /// Decides which passes count as ``earlyPasses``: only CEF's own re-ask during the pass counts. A
    /// request after the pass is a Chromium thread's or cmux's, not the truncated re-ask, and a pass that
    /// used CEF's whole time slice is not early: the fork asks for "now" because work is left.
    nonisolated struct EarlyPassWatch: Equatable, Sendable {
        /// The largest early re-ask (exclusive), in ms.
        static let earlyReask: Int64 = 2

        /// The running pass serves a delayed fire date.
        private var delayedPassRuns = false
        /// CEF asked for under ``earlyReask`` ms during that pass.
        private var reasked = false

        mutating func passBegan(servesFireDate: Bool) {
            delayedPassRuns = servesFireDate
            reasked = false
        }

        /// True when the pass that just ended was early.
        mutating func passEnded(usedWholeSlice: Bool) -> Bool {
            defer {
                delayedPassRuns = false
                reasked = false
            }
            return delayedPassRuns && reasked && !usedWholeSlice
        }

        /// A CEF request made on the main thread.
        mutating func request(milliseconds: Int64) {
            if delayedPassRuns, milliseconds < Self.earlyReask { reasked = true }
        }
    }

    /// Pass counts while input was pending, per input target.
    public nonisolated struct PassesByTarget: Equatable, Sendable {
        /// Indexed by `InputTarget.rawValue`.
        private var counts = [Int](repeating: 0, count: InputTarget.allCases.count)
        /// Passes the one-refresh bound released with input still pending: that input was not
        /// dispatched yet, so its target is unknown.
        public var boundExpired = 0
        /// Passes that ran before pending keys because a Chromium page had the keyboard
        /// (``CEFPumpInputPolicy/Admission/runForFocusedPage``).
        public var pageFocused = 0

        public init() {}

        /// Passes released right after an input to `target` was dispatched, with more input pending.
        /// Only `chromiumPage` is expected: Chromium acks its input inside the pump.
        public subscript(target: InputTarget) -> Int {
            counts[Int(target.rawValue)]
        }

        /// The counts by target name (`terminal`, `chromiumPage`, ...), `boundExpired` and `pageFocused`
        /// (`debug.cef`, `debug.input`).
        public var byName: [String: UInt64] {
            var names = ["boundExpired": UInt64(clamping: boundExpired), "pageFocused": UInt64(clamping: pageFocused)]
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

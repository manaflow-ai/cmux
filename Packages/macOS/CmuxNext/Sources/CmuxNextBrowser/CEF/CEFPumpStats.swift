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
    /// Passes for a delayed fire date that CEF answered, during the pass or within 2 ms of its end,
    /// with a request under 2 ms (``EarlyPassWatch``): the pass came before Chromium's task was due,
    /// because CEF truncates each delay to whole milliseconds against a stale `recent_now`, so one
    /// delayed task cost a second main wake. 0 once the fork sends absolute run times (p14-energy-046).
    public var earlyPasses = 0

    /// One pass's main-thread time at the 99th percentile in milliseconds, 0 before any pass.
    public var passMillisecondsP99: Double {
        passTimes.percentileNanos(0.99).map { Double($0) / 1_000_000 } ?? 0
    }

    public init() {}

    /// Decides which passes count as ``earlyPasses``. A pass that used CEF's whole time slice is not
    /// one: the fork asks for "now" because work is left.
    nonisolated struct EarlyPassWatch: Equatable, Sendable {
        /// The re-ask window after a pass, and the largest early re-ask (exclusive).
        static let window: TimeInterval = 0.002

        /// The running pass serves a delayed fire date.
        private var delayedPassRuns = false
        /// A request under ``window`` arrived during that pass.
        private var reasked = false
        /// The end of the last delayed pass not counted yet.
        private var delayedPassEnd: TimeInterval?

        mutating func passBegan(servesFireDate: Bool) {
            delayedPassRuns = servesFireDate
            reasked = false
            delayedPassEnd = nil
        }

        /// True when the pass that ended at `now` was early.
        mutating func passEnded(at now: TimeInterval, usedWholeSlice: Bool) -> Bool {
            defer {
                delayedPassRuns = false
                reasked = false
            }
            guard delayedPassRuns, !usedWholeSlice else { return false }
            if reasked { return true }
            delayedPassEnd = now
            return false
        }

        /// A CEF request at `now`; true when it makes the last delayed pass early.
        mutating func request(milliseconds: Int64, now: TimeInterval) -> Bool {
            guard TimeInterval(milliseconds) / 1_000 < Self.window else { return false }
            if delayedPassRuns {
                reasked = true
                return false
            }
            guard let end = delayedPassEnd, now - end <= Self.window else { return false }
            delayedPassEnd = nil
            return true
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

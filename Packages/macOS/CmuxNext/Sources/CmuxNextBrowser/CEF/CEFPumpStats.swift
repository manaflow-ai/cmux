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
    /// `CefDoMessageLoopWork` calls that used CEF's whole 10 ms time slice,
    /// so work may remain that CEF does not schedule again.
    public var longWorkRuns = 0
    /// Total time inside `CefDoMessageLoopWork`, in seconds.
    public var workSeconds: Double = 0
    /// Timer fires that were follow-up wakes after a pass (the safety net
    /// for delayed work CEF does not report), not CEF requests.
    public var followUpRuns = 0
    /// The gap of the pending follow-up wake in seconds, 0 when none is
    /// pending (the pump then sleeps until CEF asks).
    public var fallbackInterval: Double = 0
    /// Delayed requests from Chromium threads kept with no main wake, because the armed fire came
    /// first (``CEFPumpCrossThreadGate``); the main thread merges them at its next pass or re-arm.
    /// They are not in ``delayedRequests``.
    public var keptCrossThreadRequests = 0
    /// Timer fires held because a shown frame was late and the pump had run
    /// its one pass for that frame (`RenderStarvationGuard`); each runs after
    /// the late link's tick.
    public var lateFrameHolds = 0
    /// Passes that ran while a person's input was pending, by where the input went
    /// (``CEFPumpInputPolicy``). For other targets this stays 0 but for passes held one refresh.
    public var passesWhileInputPending = PassesByTarget()
    /// Passes the input policy held until an input's dispatch ended (one per hold).
    public var deferredForInput = 0
    /// Each pass's main-thread time while the input policy runs.
    public var passTimes = InputLatencyHistogram()

    /// One pass's main-thread time at the 99th percentile in milliseconds, 0 before any pass.
    public var passMillisecondsP99: Double {
        passTimes.percentileNanos(0.99).map { Double($0) / 1_000_000 } ?? 0
    }

    public init() {}

    /// Pass counts per input target.
    public nonisolated struct PassesByTarget: Equatable, Sendable {
        /// After input to a Chromium page: expected, Chromium acks input inside the pump.
        public var chromiumPage = 0
        /// While input for anything else was pending.
        public var other = 0

        public init() {}

        /// The counts by target name (`debug.cef`, `debug.input`).
        public var byName: [String: UInt64] {
            ["chromiumPage": UInt64(clamping: chromiumPage), "other": UInt64(clamping: other)]
        }

        mutating func add(_ target: CEFPumpInputPolicy.Target) {
            switch target {
            case .chromiumPage: chromiumPage += 1
            case .other: other += 1
            }
        }
    }
}

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
    /// `CefDoMessageLoopWork` passes by how long each held the main thread:
    /// one count per bucket of `passBucketUpperBounds`, then one for passes
    /// at or above the last bound. A bench takes the difference of two reads.
    public var passHistogram = [Int](repeating: 0, count: CEFPumpStats.passBucketUpperBounds.count + 1)
    /// The longest pass since `CefInitialize`, in seconds.
    public var maxPassSeconds: Double = 0

    /// Upper bounds of the `passHistogram` buckets, in seconds.
    public static let passBucketUpperBounds: [Double] = [0.000_25, 0.000_5, 0.001, 0.002, 0.005, 0.010]

    public init() {}

    /// Counts one pass of `seconds` in `passHistogram` and `maxPassSeconds`.
    mutating func recordPass(seconds: Double) {
        let bucket = Self.passBucketUpperBounds.firstIndex { seconds < $0 } ?? Self.passBucketUpperBounds.count
        passHistogram[bucket] += 1
        maxPassSeconds = max(maxPassSeconds, seconds)
    }
}

public import Foundation
import CmuxNextCompat
import Darwin

/// Sends every main-thread hang (a stall still running at the watchdog's
/// hang threshold, 2 s) to crash reporting with its stacks, under a budget
/// that only a flood reaches.
///
/// Before 2026-10-30 the watchdog sent at most one hang per 5 minutes, so
/// three hangs in 30 s reached Sentry as one. Now each hang is sent; the
/// budget (``defaultBudget()``: 30 at once, then one more a minute) only
/// bounds a hang loop, and every hang it drops is still counted in the
/// hour's ``StallSummary``.
///
/// ``noteHang(duration:addresses:otherThreads:)`` runs on the watchdog
/// thread while the main thread is still blocked, so a hang the person ends
/// by force quitting is sent too.
public final class MainThreadHangReporter: Sendable {
    /// Where an admitted hang goes (crash reporting in the app; a recorder in tests).
    public typealias Sink = @Sendable (MainThreadHangEvent) -> Void

    // Lock carve-out: a synchronous admit check on the watchdog thread.
    private let budget: Mutex<LagSpikeRateLimiter>
    private let isEnabled: @Sendable () -> Bool
    private let sink: Sink
    private let summary: StallSummaryRecorder?
    private let uptime: @Sendable () -> UInt64

    /// The default budget: 30 hangs at once, then one more each minute.
    public static func defaultBudget() -> LagSpikeRateLimiter {
        LagSpikeRateLimiter(minimumNanos: 0, capacity: 30, refillNanos: 60_000_000_000)
    }

    /// Reports to `reporter` when it runs, counting in its ``CrashReporter/stallSummary``.
    public convenience init(reporter: CrashReporter) {
        self.init(budget: Self.defaultBudget(), isEnabled: { reporter.isStarted }, summary: reporter.stallSummary,
                  sink: { event in reporter.reportHang(event) })
    }

    /// Test seam: an explicit budget, enabled check, summary, sink and monotonic clock.
    public init(budget: LagSpikeRateLimiter, isEnabled: @escaping @Sendable () -> Bool, summary: StallSummaryRecorder?,
                sink: @escaping Sink, uptime: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }) {
        self.budget = Mutex(budget)
        self.isEnabled = isEnabled
        self.summary = summary
        self.sink = sink
        self.uptime = uptime
    }

    /// One hang still running (watchdog thread).
    /// - Returns: whether it was sent.
    @discardableResult
    public func noteHang(duration: Duration, addresses: [UInt], otherThreads: [(name: String, addresses: [UInt])] = []) -> Bool {
        guard isEnabled() else { return false }
        let now = uptime()
        let admitted = budget.withLock { $0.admit(durationNanos: 0, nowNanos: now) }
        summary?.record(.hang(sent: admitted))
        guard admitted else { return false }
        sink(MainThreadHangEvent(duration: duration, addresses: addresses, otherThreads: otherThreads))
        return true
    }
}

public import Foundation
import CmuxNextCompat
import Darwin
import Sentry

/// Keeps this launch's ``StallSummary`` and sends each closed window
/// (``StallSummaryReport``) to crash reporting.
///
/// ``record(_:)`` runs where the watchdog calls it (the main thread for a
/// finished stall, the watchdog thread for a hang): a lock over a few
/// integers, and for the first record after a window ended a detached
/// utility task that sends the report. ``close()`` sends the open window at
/// quit and waits up to a second for it to leave. Does nothing while crash
/// reporting is off.
///
/// ```swift
/// let lag = LagSpikeReporter(reporter: reporter)  // counts into reporter.stallSummary
/// let hangs = MainThreadHangReporter(reporter: reporter)
/// ```
public final class StallSummaryRecorder: Sendable {
    /// Where a closed window goes (crash reporting in the app; a recorder in
    /// tests). `atQuit` is true for the window ``close()`` ends.
    public typealias Sink = @Sendable (_ report: StallSummaryReport, _ atQuit: Bool) -> Void

    // Lock carve-out: a synchronous count from the main thread at the end of
    // every stall; an actor hop would add a Task per stall.
    private let state: Mutex<StallSummary>
    private let isEnabled: @Sendable () -> Bool
    private let sink: Sink
    private let uptime: @Sendable () -> UInt64

    /// Sends to Sentry while it runs in this process, one window an hour
    /// (``CrashReporter/stallSummary``; every event still passes the
    /// reporter's scrubber and labels).
    public static func sentry() -> StallSummaryRecorder {
        StallSummaryRecorder(summary: StallSummary(), isEnabled: { SentrySDK.isEnabled }, sink: { report, atQuit in
            SentrySDK.capture(event: report.event())
            if atQuit { SentrySDK.flush(timeout: 1) }
        })
    }

    /// Test seam: an explicit enabled check, sink and monotonic clock.
    public init(summary: StallSummary, isEnabled: @escaping @Sendable () -> Bool, sink: @escaping Sink,
                uptime: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }) {
        state = Mutex(summary)
        self.isEnabled = isEnabled
        self.sink = sink
        self.uptime = uptime
    }

    /// Counts one stall, hang or sent spike; sends the previous window when this closed it.
    public func record(_ kind: StallSummary.Kind) {
        guard isEnabled() else { return }
        let now = uptime()
        guard let closed = state.withLock({ $0.record(kind, nowNanos: now) }) else { return }
        let sink = self.sink
        Task.detached(priority: .utility) { sink(closed, false) }
    }

    /// Sends the open window now (quit), on the calling thread.
    public func close() {
        guard isEnabled() else { return }
        let now = uptime()
        guard let closed = state.withLock({ $0.close(nowNanos: now) }) else { return }
        sink(closed, true)
    }
}

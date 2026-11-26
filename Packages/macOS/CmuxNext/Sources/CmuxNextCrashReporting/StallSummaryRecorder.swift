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
/// utility task that checks crash reporting is on and sends the report. The
/// check never runs on the calling thread: Sentry's `isEnabled` takes its
/// hub lock, which a Sentry thread can hold for seconds on a loaded Mac
/// (a 3.0 s hang at load 214, hq#18814); the callers (`LagSpikeReporter`,
/// `MainThreadHangReporter`) already count only while crash reporting runs.
/// ``close()`` sends the open window at quit and waits up to a second for it
/// to leave. Sends nothing while crash reporting is off.
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
    /// The open descriptor and pipe counts each closed window carries (off the main thread: in the send task).
    private let descriptors: @Sendable () -> (total: Int, pipes: Int)?

    /// Sends to Sentry while it runs in this process, one window an hour
    /// (``CrashReporter/stallSummary``; every event still passes the
    /// reporter's scrubber and labels).
    public static func sentry() -> StallSummaryRecorder {
        StallSummaryRecorder(summary: StallSummary(), isEnabled: { SentrySDK.isEnabled }, sink: { report, atQuit in
            SentrySDK.capture(event: report.event())
            if atQuit { SentrySDK.flush(timeout: 1) }
        }, descriptors: {
            let count = OpenDescriptors.current()
            OpenDescriptors.noteBudget(count)
            return count.map { ($0.total, $0.pipes) }
        })
    }

    /// Test seam: an explicit enabled check, sink and monotonic clock.
    public init(summary: StallSummary, isEnabled: @escaping @Sendable () -> Bool, sink: @escaping Sink,
                uptime: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) },
                descriptors: @escaping @Sendable () -> (total: Int, pipes: Int)? = { nil }) {
        state = Mutex(summary)
        self.isEnabled = isEnabled
        self.sink = sink
        self.uptime = uptime
        self.descriptors = descriptors
    }

    private func counted(_ report: StallSummaryReport) -> StallSummaryReport {
        guard let count = descriptors() else { return report }
        var report = report
        (report.openDescriptors, report.openPipes) = (count.total, count.pipes)
        return report
    }

    /// Counts one stall, hang or sent spike; sends the previous window when this closed it.
    public func record(_ kind: StallSummary.Kind) {
        let now = uptime()
        guard let closed = state.withLock({ $0.record(kind, nowNanos: now) }) else { return }
        let isEnabled = self.isEnabled
        // task-owner: none; one bounded send (and descriptor count) off the recording thread, which may be main
        Task.detached(priority: .utility) { [self] in if isEnabled() { sink(counted(closed), false) } }
    }

    /// Sends the open window now (quit), on the calling thread.
    public func close() {
        guard isEnabled() else { return }
        let now = uptime()
        guard let closed = state.withLock({ $0.close(nowNanos: now) }) else { return }
        sink(counted(closed), true)
    }
}

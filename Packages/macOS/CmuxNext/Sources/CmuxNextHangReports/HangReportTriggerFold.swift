public import CmuxNextMetrics
import CmuxNextWakeups
import os

/// What every hang report trigger (launch, MetricKit delivery, View Hang Report) folds into the app's histograms
/// before the service reads them: Chromium's own (task 107), waited for at most ``limit``, then the local daemon's
/// request latency from its metrics file (task 062, no socket request). A harvest still running at the limit folds
/// later, into the next report, as Chrome's `HistogramSynchronizer` serves what it has at its timeout
/// (content/browser/metrics/histogram_synchronizer.cc).
///
/// ```swift
/// let fold = HangReportTriggerFold(daemonMetrics: fold, daemonPID: { daemon.pid }, chromium: harvest)
/// await fold.run()
/// await service.launched()
/// ```
public struct HangReportTriggerFold: Sendable {
    /// The daemon's metrics file fold; nil folds none.
    public let daemonMetrics: DaemonMetricsFold?
    /// The local daemon's pid now; nil without one.
    public let daemonPID: @MainActor @Sendable () -> Int32?
    /// Chromium's histograms (``MetricsHarvest``); nil while feature chromiumHistograms is off.
    public let chromium: MetricsHarvest?
    /// The longest wait for `chromium`.
    public let limit: Duration
    /// The clock `limit` runs on.
    public let clock: any Clock<Duration>
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "hang-reports")

    /// Makes the value from its parts.
    public init(daemonMetrics: DaemonMetricsFold?, daemonPID: @escaping @MainActor @Sendable () -> Int32?, chromium: MetricsHarvest?,
                limit: Duration = .seconds(1), clock: any Clock<Duration> = ContinuousClock()) {
        self.daemonMetrics = daemonMetrics
        self.daemonPID = daemonPID
        self.chromium = chromium
        self.limit = limit
        self.clock = clock
    }

    /// One trigger's folds: Chromium's harvest within ``limit``, then the daemon's.
    public func run() async {
        await harvestChromium(within: limit)
        guard let daemonMetrics else { return }
        let pid = await daemonPID()
        let outcome = await daemonMetrics.fold(pid: pid)
        // Every outcome is counted in the fold's tally (`debug.shipping_mode`); one that left the daemon out is logged.
        let described = String(describing: outcome), daemon = pid ?? 0
        switch outcome {
        case .folded, .noDaemon, .busy:
            break
        case .missing, .noStore, .cancelled:
            logger.notice("daemon metrics not folded: \(described, privacy: .public), pid \(daemon, privacy: .public)")
        case .unreadable, .cursorUnwritten:
            logger.error("daemon metrics not folded: \(described, privacy: .public), pid \(daemon, privacy: .public)")
        }
    }

    /// One Chromium harvest, waited for at most `wait`; true when it finished in time.
    @discardableResult
    public func harvestChromium(within wait: Duration) async -> Bool {
        guard let chromium else { return false }
        return await Deadline(wait, clock: clock).value("hang-reports.chromium") { await chromium.run() } != nil
    }
}

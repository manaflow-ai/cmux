/// Folds another process's histograms into the app's store at a report trigger (Chromium's, p09-observability task
/// 107), as Chrome's `HistogramSynchronizer` fetches the child processes' histograms before chrome://histograms or a
/// metrics log reads the browser's (content/browser/metrics/histogram_synchronizer.cc). Like it, a caller waits a
/// bounded time and then reads what the store has: a harvest that finishes later still folds into the store, and the
/// next read shows it.
///
/// ```swift
/// let harvest = MetricsHarvest(name: "chromium", run: { _ = await chromium.harvest() }, tally: { await chromium.tally.byName })
/// ```
public struct MetricsHarvest: Sendable {
    /// The source's name in `metrics.snapshot` and `debug.shipping_mode` (`chromium`).
    public let name: String
    /// Folds the source's new samples into the store. Callers bound the wait.
    public let run: @Sendable () async -> Void
    /// How often each harvest outcome happened this launch, by snake_case name (`folded`, `unsupported`, ...).
    public let tally: @Sendable () async -> [String: UInt64]

    /// Makes the value from its parts.
    public init(name: String, run: @escaping @Sendable () async -> Void, tally: @escaping @Sendable () async -> [String: UInt64]) {
        self.name = name
        self.run = run
        self.tally = tally
    }
}

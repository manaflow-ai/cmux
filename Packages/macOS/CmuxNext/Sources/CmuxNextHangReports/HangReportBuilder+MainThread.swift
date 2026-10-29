/// The main-thread part of a report: `active_seconds` and the watchdog's
/// main-turn and input-queueing histograms (`MainTurnHistogram` in
/// CmuxNextControl) as two more ``IntervalHistogram`` entries in category
/// ``HangReport/mainThreadCategory``, so the wire gains no histogram type. Counts and bucket edges
/// only. A turn is Chromium's `kExecutionOnly` interval, input queueing the queue part of its
/// `kQueueAndExecution` (content/browser/scheduler/responsiveness/calculator.h).
extension HangReportBuilder {
    /// What a report carries (``MainThreadReportLedger/take()``): the active seconds and each
    /// histogram's counts since the last queued report (the cumulative `MainTurnHistogram` read minus
    /// the read the last queued report ended at), over `MainTurnHistogram.edgesNanos`.
    public struct MainThreadInput: Sendable, Equatable {
        /// ``ActiveTimeLedger/seconds(atNanos:)``: active seconds not yet sent.
        public var activeSeconds: Int
        /// The fine bucket edges in nanoseconds, increasing (`MainTurnHistogram.edgesNanos`).
        public var edgesNanos: [UInt64]
        /// The main-turn counts since the last queued report: one per bucket, `edgesNanos.count + 1`.
        public var turnCounts: [UInt64]
        /// The input-queueing counts since the last queued report, in the same buckets.
        public var inputQueueingCounts: [UInt64]

        /// Makes the value from its parts.
        public init(activeSeconds: Int, edgesNanos: [UInt64], turnCounts: [UInt64], inputQueueingCounts: [UInt64]) {
            self.activeSeconds = activeSeconds
            self.edgesNanos = edgesNanos
            self.turnCounts = turnCounts
            self.inputQueueingCounts = inputQueueingCounts
        }
    }

    /// The most fine edges an input may have; a larger histogram is left out (it bounds the work).
    static let maxMainThreadEdges = 1_024

    /// Sets `active_seconds` and appends the two histograms; at ``HangReport/maxIntervals`` they
    /// stay and MetricKit's last intervals go, as in `HangReportService.fitted` at the body cap. A
    /// histogram whose shape does not match its edges, or that counted nothing, is left out.
    static func addMainThread(_ input: MainThreadInput, to report: inout HangReport) {
        report.activeSeconds = min(max(0, input.activeSeconds), HangReport.maxActiveSeconds)
        let histograms = [(HangReport.mainTurnInterval, input.turnCounts),
                          (HangReport.inputQueueingInterval, input.inputQueueingCounts)]
            .compactMap { name, counts in mainThreadInterval(name: name, counts: counts, edgesNanos: input.edgesNanos) }
        report.intervals = Array(report.intervals.prefix(HangReport.maxIntervals - histograms.count)) + histograms
    }

    static func mainThreadInterval(name: String, counts: [UInt64], edgesNanos: [UInt64]) -> IntervalHistogram? {
        guard let buckets = mainThreadBuckets(counts: counts, edgesNanos: edgesNanos) else { return nil }
        let count = buckets.reduce(0) { $0.saturatingAdding($1.count) }
        guard count > 0 else { return nil }
        return IntervalHistogram(category: HangReport.mainThreadCategory, name: name, count: count, buckets: buckets,
                                 hitchMsPerS: nil)
    }

    /// The fine buckets merged in runs of equal length, the shortest runs that fit in
    /// ``HistogramBucket/maxBuckets`` report buckets (runs of 2 for `MainTurnHistogram`'s 69, so 26
    /// buckets). Nil when `counts` does not have one count per bucket of `edgesNanos` or the edges do
    /// not increase.
    static func mainThreadBuckets(counts: [UInt64], edgesNanos: [UInt64]) -> [HistogramBucket]? {
        guard !edgesNanos.isEmpty, edgesNanos.count <= maxMainThreadEdges, counts.count == edgesNanos.count + 1,
              zip(edgesNanos, edgesNanos.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }
        // A run as long as the edges leaves two buckets (below and from the last edge), so one fits.
        for run in 1...edgesNanos.count {
            let buckets = mainThreadBuckets(counts: counts, edgesNanos: edgesNanos, run: run)
            if buckets.count <= HistogramBucket.maxBuckets { return HistogramBucket.normalized(buckets) }
        }
        return nil
    }

    /// The report buckets of runs of `run` fine buckets. A report bucket ends on a fine edge (every
    /// `run`-th one, and the last), so each fine count lands in exactly one report bucket; its edges
    /// are those fine edges rounded to the nearest millisecond, the wire's unit, and a run whose
    /// rounded edge does not pass the one below joins the next run. Zero counts are kept, so the
    /// result's length is the bucket count the edges need.
    static func mainThreadBuckets(counts: [UInt64], edgesNanos: [UInt64], run: Int) -> [HistogramBucket] {
        var buckets: [HistogramBucket] = []
        var lowMs = 0
        var pending = 0
        for (index, count) in counts.enumerated() {
            pending = pending.saturatingAdding(Int(clamping: count))
            guard index < edgesNanos.count, (index + 1) % run == 0 || index == edgesNanos.count - 1 else { continue }
            let highMs = roundedWholeMilliseconds(edgesNanos[index])
            guard highMs > lowMs else { continue }
            buckets.append(HistogramBucket(lowMs: lowMs, highMs: highMs, count: pending))
            lowMs = highMs
            pending = 0
        }
        buckets.append(HistogramBucket(lowMs: lowMs, highMs: HistogramBucket.maxMs, count: pending))
        return buckets
    }

    /// `nanos` to the nearest whole millisecond, at most ``HistogramBucket/maxMs``.
    static func roundedWholeMilliseconds(_ nanos: UInt64) -> Int {
        min(Int(clamping: nanos / 1_000_000 + (nanos % 1_000_000 >= 500_000 ? 1 : 0)), HistogramBucket.maxMs)
    }
}

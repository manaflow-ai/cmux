import CmuxNextCompat
public import CmuxNextMetrics

/// Counts the new main-thread call sites of the blocking detector in `blocking.violations` (one sample of 1 per
/// site), including the sites that reached ``BlockingReportSink`` before the app's metrics store was attached.
///
/// The app attaches its ``MetricsStore`` on the files lane (``MetricsStore/startApp(directory:channel:work:runtime:attached:)``),
/// and the detector replays the launch's early sites to the sink on its drain queue; nothing orders the two. A
/// ``Metrics`` record before the store is attached records nothing, so the counter keeps those sites and records
/// them at the first ``count()`` or ``metricsAttached()`` that sees the store. Chrome's histograms do not lose early
/// samples either: they record on the heap until the persistent allocator exists
/// (base/metrics/persistent_histogram_allocator.cc).
///
/// Only the sink of a build with the blocking detector (Debug, the Nightly's `CMUX_BLOCKING_CHECKS`) counts; the
/// app makes the counter in every build, so its launch path needs no build condition.
///
/// Lock-free: one atomic holds the sites kept so far, or ``recording`` once they were recorded; the one transition
/// to ``recording`` hands the kept sites to exactly one caller.
///
/// ```swift
/// let violations = BlockingViolationCounter(metrics: Metrics())
/// MetricsStore.startApp(directory: folder, channel: "nightly", work: work, attached: { violations.metricsAttached() })
/// ```
public final class BlockingViolationCounter: Sendable {
    /// The state once the store is attached and the kept sites were recorded.
    private static let recording = -1

    private let metrics: Metrics
    /// The sites kept while no store was attached, or ``recording``.
    private let kept = Atomic<Int>(0)

    /// Makes the value from its parts.
    ///
    /// - Parameter metrics: Where the samples go (its runtime's attached store).
    public init(metrics: Metrics) {
        self.metrics = metrics
    }

    /// Counts one new main-thread site (the detector's drain queue).
    public func count() {
        add(1)
    }

    /// Records the sites kept so far; call it once the metrics store is attached (any thread). It does nothing
    /// while the runtime has no store.
    public func metricsAttached() {
        add(0)
    }

    private func add(_ sites: Int) {
        var state = kept.load(ordering: .acquiring)
        while state != Self.recording {
            let attached = MetricsStore.attached(to: metrics.runtime) != nil
            let next = attached ? Self.recording : state + sites
            let (exchanged, original) = kept.compareExchange(expected: state, desired: next, ordering: .acquiringAndReleasing)
            guard exchanged else {
                state = original
                continue
            }
            if attached { record(state + sites) }
            return
        }
        record(sites)
    }

    private func record(_ sites: Int) {
        for _ in 0..<sites { metrics.record(.blockingViolations, 1) }
    }
}

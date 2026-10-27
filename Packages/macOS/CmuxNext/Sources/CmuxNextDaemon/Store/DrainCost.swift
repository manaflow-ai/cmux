public import CmuxNextWakeups

/// What the store's drains of the event inbox cost: one sample per batch in a duration histogram,
/// the events it applied, and the counts of the whole-list passes a batch can start. A storm of
/// title, scroll or status events in hidden workspaces flattens no sidebar and changes no
/// workspace list, and the counters prove it. `debug.drain_cost` reports it and
/// script-storm-bench `--hidden` reads its p99.
///
/// The histogram is the owner ledger's (``MainOwnerLedger/Histogram``: four buckets per power of
/// two, Chromium's exponential `UMA_HISTOGRAM_CUSTOM_MICROSECONDS_TIMES` in
/// base/metrics/histogram_macros.h at a finer step). The field catalog (`HistogramID`) has no drain
/// histogram yet; adding one is a follow-up to p09-observability-000.
///
/// ```swift
/// let p99 = store.drainCost.histogram.percentile(0.99)   // ns
/// ```
public struct DrainCost: Sendable, Equatable {
    /// Drains that applied a batch, by duration in ns.
    public private(set) var histogram = MainOwnerLedger.Histogram()
    /// Events those batches held (after the inbox coalesced them).
    public private(set) var events = 0
    /// Sidebar flattenings (`DaemonStore.recomputeSidebar`) by any apply: a batch that only
    /// changes records inside workspaces runs none.
    public internal(set) var sidebarFlattens = 0
    /// `onWorkspaceListChanged` calls: only a workspace joining or leaving the list makes one.
    public internal(set) var listChanges = 0

    public init() {}

    /// Drains that applied a batch.
    public var batches: Int { histogram.count }

    /// Counts one drain of `duration` that applied `events` events.
    mutating func record(_ duration: Duration, events count: Int) {
        histogram.add(duration)
        events &+= count
    }

    /// The time `body` takes on `clock` (the store's injected ``DaemonStore/drainClock``).
    static func measured<C: Clock, T>(on clock: C, _ body: () -> T) -> (T, Duration) where C.Duration == Duration {
        let start = clock.now
        let result = body()
        return (result, start.duration(to: clock.now))
    }
}

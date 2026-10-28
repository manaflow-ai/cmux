import CmuxNextCompat

/// Whether the App's Chromium engine was built (``ChromiumEngineSlot/built``), readable from any thread: only an
/// engine starts Chromium, so before it a histogram harvest (``CEFHistogramHarvest``, p09-observability 107) answers
/// notStarted without a main-thread hop, and a report trigger never waits on a stalled main thread for a Chromium
/// that is not there.
nonisolated final class ChromiumEngineBuiltFlag: Sendable {
    private let built = Atomic<Bool>(false)

    /// Whether the slot built its engine.
    var isBuilt: Bool { built.load(ordering: .acquiring) }

    /// The slot built its engine (main thread, once).
    func markBuilt() {
        built.store(true, ordering: .releasing)
    }
}

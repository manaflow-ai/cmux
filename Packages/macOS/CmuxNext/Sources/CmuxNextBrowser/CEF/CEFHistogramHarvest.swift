public import CmuxNextMetrics
internal import CmuxNextTrace

/// Folds Chromium's own histograms into the app's field histograms as `chromium.<name>`
/// (plans/cmux-next/chrome-parity/p09-observability.md task 107), at report triggers only: no timer and no
/// polling. Each ``harvest()`` asks Chromium once for the samples of ``allowlist`` since the previous
/// snapshot (the fork merges the child processes' histograms first, as chrome://histograms does) and adds
/// them to the store (``MetricsStore/foldChromium(_:count:sum:buckets:)``); the report then sends them with
/// the app's own (``MetricsStore/delta()``), as Chrome's `HistogramSnapshotManager` sends deltas.
///
/// The fold runs in a task of its own: a caller that stops waiting (``metricsHarvest``'s callers bound the wait, as
/// Chrome's `HistogramSynchronizer` does) leaves it to finish into the store, and a harvest asked while one runs joins
/// it. Before Chromium runs, a harvest answers ``CEFHistogramHarvestError/notStarted`` without a main-thread hop.
///
/// ```swift
/// let harvest = services.cache.chromium.histograms   // the engine slot's one harvest
/// _ = await harvest.harvest()   // before a report reads the store
/// ```
public actor CEFHistogramHarvest {
    /// One snapshot of `names` through the engine (``CEFEngine/histogramSnapshot(names:)``; tests a fake).
    public typealias Snapshot = @MainActor @Sendable (_ names: [String]) async -> Result<[CEFHistogramDelta], CEFHistogramHarvestError>

    /// What one harvest did.
    public nonisolated enum Outcome: Sendable, Equatable {
        /// `histograms` of Chromium's histograms had new samples (`samples` in all); they are in the store.
        case folded(histograms: Int, samples: UInt64)
        /// No snapshot: see the error.
        case failed(CEFHistogramHarvestError)
        /// The app has no metrics store: nothing was asked.
        case noStore
    }

    /// How often each outcome happened.
    public nonisolated struct Tally: Sendable, Equatable {
        public var folded = 0
        public var samples: UInt64 = 0
        public var notStarted = 0
        public var unsupported = 0
        public var refused = 0
        public var abandoned = 0
        public var noStore = 0

        public init() {}

        /// Each count under its snake_case name.
        public var byName: [String: UInt64] {
            ["folded": UInt64(folded), "samples": samples, "not_started": UInt64(notStarted), "unsupported": UInt64(unsupported),
             "refused": UInt64(refused), "abandoned": UInt64(abandoned), "no_store": UInt64(noStore)]
        }

        mutating func count(_ outcome: Outcome) {
            switch outcome {
            case let .folded(histograms: _, samples: added):
                folded += 1
                samples &+= added
            case .failed(.notStarted): notStarted += 1
            case .failed(.unsupported): unsupported += 1
            case .failed(.refused): refused += 1
            case .failed(.abandoned): abandoned += 1
            case .noStore: noStore += 1
            }
        }
    }

    /// Chromium's names a harvest asks for: the catalog's ``HistogramID/Chromium`` cases, the fork's allowlist.
    public nonisolated static let allowlist: [String] = HistogramID.Chromium.allCases.map(\.rawValue)

    private let takeSnapshot: Snapshot
    private let isRunning: @Sendable () -> Bool
    private let store: @Sendable () -> MetricsStore?
    /// The fold in progress; a harvest asked meanwhile joins it.
    private var inFlight: Task<Outcome, Never>?
    /// Every outcome so far.
    public private(set) var tally = Tally()

    /// - Parameters:
    ///   - snapshot: Runs one snapshot (``CEFEngine/histogramSnapshot(names:)``; tests a fake).
    ///   - isRunning: Whether Chromium runs now, read off the main thread; false answers notStarted without `snapshot`.
    ///   - store: The store the deltas go to.
    public init(snapshot: @escaping Snapshot, isRunning: @escaping @Sendable () -> Bool = { true },
                store: @escaping @Sendable () -> MetricsStore?) {
        takeSnapshot = snapshot
        self.isRunning = isRunning
        self.store = store
    }

    /// A harvest over the App's engine slot into the app runtime's store. It builds no engine: before a Chromium need
    /// built one (`built`, read off the main thread), a harvest is ``CEFHistogramHarvestError/notStarted`` with no hop.
    init(engine slot: ChromiumEngineSlot, built: ChromiumEngineBuiltFlag) {
        self.init(snapshot: { [weak slot] names in
            guard let engine = slot?.built else { return .failure(.notStarted) }
            return await engine.histogramSnapshot(names: names)
        }, isRunning: { built.isBuilt }, store: { MetricsStore.attached(to: TraceRuntime.shared) })
    }

    /// This harvest as the report triggers' seam (`metrics.snapshot`, hang reports), under the name `chromium`.
    public nonisolated var metricsHarvest: MetricsHarvest {
        MetricsHarvest(name: "chromium", run: { _ = await self.harvest() }, tally: { await self.tally.byName })
    }

    /// Asks Chromium for ``allowlist``'s new samples and folds them into the store; counts the outcome. Joins a fold
    /// in progress. A caller that stops waiting does not stop the fold: its samples reach the store when it ends.
    @discardableResult
    public func harvest() async -> Outcome {
        if let inFlight { return await inFlight.value }
        guard let store = store() else { return finish(.noStore) }
        guard isRunning() else { return finish(.failed(.notStarted)) }
        // task-owner: one fold, owned by the actor until it ends (the fork always sends its end call); it inherits
        // the caller's priority and is not cancelled with the caller.
        let running = Task { self.finish(await self.fold(into: store)) }
        inFlight = running
        return await running.value
    }

    /// Counts `outcome` and ends the fold in progress.
    private func finish(_ outcome: Outcome) -> Outcome {
        inFlight = nil
        tally.count(outcome)
        return outcome
    }

    /// One snapshot of `names`; a name outside ``allowlist`` is refused before Chromium is asked.
    public func snapshot(names: [String]) async -> Result<[CEFHistogramDelta], CEFHistogramHarvestError> {
        guard !names.isEmpty, names.allSatisfy({ Self.allowlist.contains($0) }) else { return .failure(.refused) }
        return await takeSnapshot(names)
    }

    private func fold(into store: MetricsStore) async -> Outcome {
        switch await snapshot(names: Self.allowlist) {
        case .failure(let error):
            return .failed(error)
        case .success(let deltas):
            var histograms = 0
            var samples: UInt64 = 0
            for delta in deltas {
                let count = UInt64(clamping: delta.count)
                guard let id = HistogramID.Chromium(rawValue: delta.name), count > 0 else { continue }
                let buckets = delta.buckets.filter { $0.count > 0 }
                    .map { MetricsStore.ChromiumBucket(minimum: $0.minimum, count: UInt64(clamping: $0.count)) }
                guard store.foldChromium(id, count: count, sum: UInt64(clamping: delta.sum), buckets: buckets) else { continue }
                histograms += 1
                samples &+= count
            }
            return .folded(histograms: histograms, samples: samples)
        }
    }
}

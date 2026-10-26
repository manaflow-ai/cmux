import CmuxNextWakeups
import Foundation
public import Observation

/// The Task Manager page's state: the latest ``TaskManagerSnapshot`` and the
/// selected rows. While started it takes one sample per `interval` from its
/// ``TaskManagerSampleSource``, each next sample a one-shot ``DemandTimer`` deadline armed after
/// the previous one finished; stopped, it samples nothing.
///
/// With `memorySaved` (the `taskManagerMemorySaved` feature) the snapshot also lists the items
/// Memory Saver discarded, each with the memory it held in its last sample before the discard: the
/// discarder's number when it had one, else the model's own last sample of the item. Chrome shows the
/// same number from `PreDiscardResourceUsage`
/// (chrome/browser/performance_manager/public/user_tuning/user_performance_tuning_manager.h).
///
/// Kill Process goes through `kill`, which the App wires to the
/// `taskManager.killProcess` action (one path for the row menu, the page's
/// button, the palette and the CLI).
///
/// ```swift
/// let model = TaskManagerModel(source: FakeSource(), kill: { _ in })
/// await model.refresh()
/// ```
@MainActor @Observable
public final class TaskManagerModel {
    public private(set) var snapshot: TaskManagerSnapshot = .empty
    /// The selected rows' processes.
    public var selection: Set<ProcessKey> = []
    /// Samples taken since the model was made (tests, diagnostics).
    public private(set) var sampleCount = 0
    /// True while the periodic refresh runs.
    public var isRunning: Bool { running }

    @ObservationIgnored public let interval: Duration
    /// Whether the snapshot lists the discarded items and what they saved (`taskManagerMemorySaved`).
    @ObservationIgnored public let memorySaved: Bool
    @ObservationIgnored private weak var source: (any TaskManagerSampleSource)?
    @ObservationIgnored private let timer: DemandTimer
    @ObservationIgnored private let killAction: @MainActor (ProcessKey) -> Void
    @ObservationIgnored private var previous: TaskManagerSampleSet?
    /// Each item's memory in the latest sample, by tab id, for an item discarded after that sample.
    /// Only the items of the latest sample are kept.
    @ObservationIgnored private var itemBytes: [String: UInt64] = [:]
    @ObservationIgnored private var running = false
    /// The first sample start() takes; stop() cancels it.
    @ObservationIgnored private var firstSample: Task<Void, Never>?
    /// Bumped by stop(), so a sample or deadline of an earlier start does nothing.
    @ObservationIgnored private var generation: UInt64 = 0

    /// - Parameters:
    ///   - source: Takes the samples; held weakly (the App owns it).
    ///   - interval: Time between samples while started (default one second, as Activity Monitor).
    ///   - clock: The clock the wait between samples runs on; tests pass their own.
    ///   - memorySaved: Lists the discarded items and what they saved (`taskManagerMemorySaved`, default off).
    ///   - kill: Runs Kill Process for one process (it asks first).
    public init(source: any TaskManagerSampleSource, interval: Duration = .seconds(1),
                clock: any Clock<Duration> = ContinuousClock(), memorySaved: Bool = false,
                kill: @escaping @MainActor (ProcessKey) -> Void) {
        self.source = source
        self.interval = interval
        self.memorySaved = memorySaved
        self.timer = DemandTimer(owner: "TaskManager.sample", clock: clock)
        self.killAction = kill
    }

    /// The page's title.
    public static var title: String { TaskManagerStrings.title }

    /// Starts sampling once per `interval` (a sample at once). Idempotent.
    public func start() {
        guard !running else { return }
        running = true
        let generation = generation
        firstSample = Task { [weak self] in await self?.sample(generation) }
    }

    /// Stops sampling and forgets the last sample (the next start has no CPU until its second sample,
    /// and an item discarded meanwhile shows only the discarder's number).
    public func stop() {
        firstSample?.cancel()
        firstSample = nil
        timer.cancel()
        generation &+= 1
        running = false
        previous = nil
        itemBytes = [:]
    }

    /// One periodic sample, then the deadline for the next. A sample that returns after stop() is
    /// dropped before it touches the snapshot.
    private func sample(_ generation: UInt64) async {
        guard generation == self.generation, let source else { return }
        let set = await source.sample()
        guard generation == self.generation, !Task.isCancelled else { return }
        apply(set)
        timer.schedule(after: interval) { @MainActor [weak self] in
            await self?.sample(generation)
        }
    }

    /// Takes one sample now and updates the rows.
    public func refresh() async {
        guard let source else { return }
        apply(await source.sample())
    }

    private func apply(_ set: TaskManagerSampleSet) {
        var next = TaskManagerSnapshot(current: set, previous: previous)
        if memorySaved { next.setDiscarded(savedMemory(set)) }
        snapshot = next
        previous = set
        sampleCount += 1
        selection.formIntersection(Set(snapshot.rows.map(\.id)))
    }

    /// The discarded items of `set`, each with what it saved, and every item's memory noted for a later
    /// discard. A discarded item keeps the number it had when it was discarded: its processes are gone,
    /// so a later sample says nothing about it.
    private func savedMemory(_ set: TaskManagerSampleSet) -> [TaskManagerDiscardedItem] {
        let items = set.discarded.map { item in
            var item = item
            if item.savedBytes == nil { item.savedBytes = itemBytes[item.id] }
            return item
        }
        let discarded = Set(items.map(\.id))
        var noted = Self.itemMemory(set.resources).filter { !discarded.contains($0.key) }
        for item in items { if let bytes = item.savedBytes { noted[item.id] = bytes } }
        itemBytes = noted
        return items
    }

    /// Each available tab's memory in `resources`: its processes' footprint (a process several tabs
    /// share split evenly between them) plus its app-side estimate. Chrome estimates a page the same
    /// way (`PageNodeImpl::EstimatePrivateFootprintSize`, components/performance_manager/graph/
    /// page_node_impl.cc: the sum of its frames' shares of their process's footprint). A tab with
    /// nothing measured is left out.
    private static func itemMemory(_ resources: ResourceSampleSet) -> [String: UInt64] {
        var sharers: [ProcessKey: UInt64] = [:]
        for tab in resources.tabs { for process in Set(tab.processes) { sharers[process, default: 0] += 1 } }
        var bytes: [String: UInt64] = [:]
        for tab in resources.tabs where tab.available {
            let own = Set(tab.processes).reduce(UInt64(0)) { total, process in
                guard let memory = resources.samples[process]?.memoryBytes else { return total }
                return total &+ memory / max(sharers[process] ?? 1, 1)
            }
            let total = own &+ tab.estimatedAppBytes
            if total > 0 { bytes[tab.tabID] = total }
        }
        return bytes
    }

    /// Kill Process for `key` (asks first through the action).
    public func kill(_ key: ProcessKey) {
        killAction(key)
    }

    /// The one selected row, for the Kill Process button.
    public var selectedRow: TaskManagerRow? {
        guard selection.count == 1, let key = selection.first else { return nil }
        return snapshot.row(key)
    }
}

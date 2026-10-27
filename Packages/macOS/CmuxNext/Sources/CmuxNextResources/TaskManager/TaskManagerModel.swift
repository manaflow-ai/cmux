public import CmuxNextWakeups
import Foundation
public import Observation

/// The Task Manager page's state: the latest ``TaskManagerSnapshot`` and the
/// selected rows. While started it takes one sample per `interval` from its
/// ``TaskManagerSampleSource``, each next sample a one-shot `MainDeadline` (class `visible`: the page
/// shows it) armed after the previous one finished; stopped, it samples nothing.
///
/// With `memorySaved` (the `taskManagerMemorySaved` feature) the snapshot also lists the items
/// Memory Saver discarded, as the source reports them, each with the memory the discarder recorded
/// when it discarded the item. The model keeps no number of its own: as in Chrome, where the
/// discarder records `PreDiscardResourceUsage` on the page
/// (chrome/browser/performance_manager/public/user_tuning/user_performance_tuning_manager.h), the
/// page shows the same number however often it is closed and opened again.
///
/// Kill Process goes through `kill`, which the App wires to the
/// `taskManager.killProcess` action (one path for the row menu, the page's
/// button, the palette and the CLI).
///
/// ```swift
/// let model = TaskManagerModel(source: FakeSource(), deadlines: deadlines, kill: { _ in })
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
    /// The next sample's deadline.
    @ObservationIgnored private let timer: MainDeadline
    @ObservationIgnored private let killAction: @MainActor (ProcessKey) -> Void
    @ObservationIgnored private var previous: TaskManagerSampleSet?
    @ObservationIgnored private var running = false
    /// The first sample start() takes; stop() cancels it.
    @ObservationIgnored private var sampling: Task<Void, Never>?
    /// Bumped by stop(), so a sample or deadline of an earlier start does nothing.
    @ObservationIgnored private var generation: UInt64 = 0

    /// - Parameters:
    ///   - source: Takes the samples; held weakly (the App owns it).
    ///   - deadlines: The app's one deadline placer (the wait between samples).
    ///   - interval: Time between samples while started (default one second, as Activity Monitor).
    ///   - memorySaved: Lists the discarded items and what they saved (`taskManagerMemorySaved`, default off).
    ///   - kill: Runs Kill Process for one process (it asks first).
    public init(source: any TaskManagerSampleSource, deadlines: MainDeadlineScheduler, interval: Duration = .seconds(1),
                memorySaved: Bool = false, kill: @escaping @MainActor (ProcessKey) -> Void) {
        self.source = source
        self.interval = interval
        self.memorySaved = memorySaved
        // `visible`: the page shows each sample; a flexible wake (8 ms leeway) is far inside a 1 s period.
        timer = MainDeadline(owner: "TaskManager.sample", workClass: .visible, scheduler: deadlines)
        self.killAction = kill
    }

    /// The page's title.
    public static var title: String { TaskManagerStrings.title }

    /// Starts sampling once per `interval` (a sample at once). Idempotent.
    public func start() {
        guard !running else { return }
        running = true
        startSample(generation)
    }

    /// Stops sampling and forgets the last sample (the next start has no CPU until its second sample).
    public func stop() {
        sampling?.cancel()
        sampling = nil
        timer.cancel()
        generation &+= 1
        running = false
        previous = nil
    }

    /// Starts one periodic sample of start `generation`.
    private func startSample(_ generation: UInt64) {
        // task-owner: stored in sampling; stop() cancels it, and a stale generation applies nothing
        // main-hop-allow: only awaits the main-actor sample source, whose daemon and process reads run off main; one resume applies it
        sampling = Task { [weak self] in await self?.sample(generation) }
    }

    /// One periodic sample, then the deadline for the next. A sample that returns after stop() is
    /// dropped before it touches the snapshot.
    private func sample(_ generation: UInt64) async {
        guard generation == self.generation, let source else { return }
        let set = await source.sample()
        guard generation == self.generation, !Task.isCancelled else { return }
        apply(set)
        timer.schedule(after: interval) { [weak self] in self?.startSample(generation) }
    }

    /// Takes one sample now and updates the rows.
    public func refresh() async {
        guard let source else { return }
        apply(await source.sample())
    }

    private func apply(_ set: TaskManagerSampleSet) {
        var next = TaskManagerSnapshot(current: set, previous: previous)
        if memorySaved { next.setDiscarded(set.discarded) }
        snapshot = next
        previous = set
        sampleCount += 1
        selection.formIntersection(Set(snapshot.rows.map(\.id)))
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

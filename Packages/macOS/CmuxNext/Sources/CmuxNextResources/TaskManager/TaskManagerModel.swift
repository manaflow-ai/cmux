import CmuxNextWakeups
import Foundation
public import Observation

/// The Task Manager page's state: the latest ``TaskManagerSnapshot`` and the
/// selected rows. While started it takes one sample per `interval` from its
/// ``TaskManagerSampleSource``, each next sample a one-shot ``DemandTimer`` deadline armed after
/// the previous one finished; stopped, it samples nothing.
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
    @ObservationIgnored private weak var source: (any TaskManagerSampleSource)?
    @ObservationIgnored private let timer: DemandTimer
    @ObservationIgnored private let killAction: @MainActor (ProcessKey) -> Void
    @ObservationIgnored private var previous: TaskManagerSampleSet?
    @ObservationIgnored private var running = false
    /// The first sample start() takes; stop() cancels it.
    @ObservationIgnored private var firstSample: Task<Void, Never>?
    /// Bumped by stop(), so a sample or deadline of an earlier start does nothing.
    @ObservationIgnored private var generation: UInt64 = 0

    /// - Parameters:
    ///   - source: Takes the samples; held weakly (the App owns it).
    ///   - interval: Time between samples while started (default one second, as Activity Monitor).
    ///   - clock: The clock the wait between samples runs on; tests pass their own.
    ///   - kill: Runs Kill Process for one process (it asks first).
    public init(source: any TaskManagerSampleSource, interval: Duration = .seconds(1),
                clock: any Clock<Duration> = ContinuousClock(), kill: @escaping @MainActor (ProcessKey) -> Void) {
        self.source = source
        self.interval = interval
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

    /// Stops sampling and forgets the last sample (the next start has no CPU until its second sample).
    public func stop() {
        firstSample?.cancel()
        firstSample = nil
        timer.cancel()
        generation &+= 1
        running = false
        previous = nil
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
        snapshot = TaskManagerSnapshot(current: set, previous: previous)
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

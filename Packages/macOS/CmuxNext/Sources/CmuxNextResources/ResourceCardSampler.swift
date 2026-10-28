public import CmuxNextWakeups
import Foundation

/// Takes one sample of a target: resolves its tabs and their processes and
/// reads their counters. The App implements it (daemon `terminal-resources`
/// for terminals, engine process ids for pages); the demo uses
/// ``MockResourceSource``. Called only while a card is open or a
/// `resources` request runs, never in the background.
public protocol ResourceSampleSource: AnyObject {
    @MainActor func sample(_ target: ResourceTarget) async -> ResourceSampleSet
}

/// Keeps one open card's numbers fresh: a sample when the card starts
/// (hover start), another after `interval` (the first CPU value), then one
/// per `interval` while the card stays open. Each next sample is a
/// one-shot `MainDeadline` (class `visible`: the card shows it) armed after
/// the previous sample finished, so nothing runs once ``close()`` is called
/// and nothing ever runs while no card is open.
///
/// Each sample's report lands on the card as one visible task on the app's
/// `MainWorkScheduler` (Chrome's PostTaskAndReplyWithResult, base/task/thread_pool.h):
/// the sampling task runs off main, and only the source's own main-actor
/// resolution and the landing run on main.
///
/// ```swift
/// let sampler = ResourceCardSampler()
/// sampler.setSource(services.resources, deadlines: services.mainDeadlines)
/// sampler.open(.tab(id)) { report in card.show(report) }
/// ```
@MainActor
public final class ResourceCardSampler {
    public typealias Update = @MainActor (ResourceReport) -> Void

    public let interval: Duration
    public private(set) weak var source: (any ResourceSampleSource)?
    /// The next sample's deadline, made on the scheduler the source came with.
    private var timer: MainDeadline?
    /// Where each report lands: that scheduler's `MainWorkScheduler`.
    private var work: MainWorkScheduler?
    /// The sample running; ``close()`` cancels it.
    private var sampling: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var onUpdate: Update?
    private var latest: ResourceSampleSet?
    public private(set) var target: ResourceTarget?
    /// The last report, for a card that appears after sampling started.
    public private(set) var report: ResourceReport?
    /// Samples taken since the card opened (tests, diagnostics).
    public private(set) var sampleCount = 0

    /// A sampler with no source: it samples nothing until ``setSource(_:deadlines:)``.
    public init(interval: Duration = .seconds(1)) {
        self.interval = interval
    }

    public var isOpen: Bool { target != nil }
    /// True while the next sample's deadline is pending.
    public var isScheduled: Bool { timer?.isScheduled ?? false }

    /// Samples from `source` (nil: nothing), each next sample placed on `deadlines`, the app's one deadline
    /// scheduler (`AppServices.mainDeadlines`), whose `MainWorkScheduler` each report lands on.
    public func setSource(_ source: (any ResourceSampleSource)?, deadlines: MainDeadlineScheduler) {
        guard source !== self.source else { return }
        close()
        self.source = source
        timer = source == nil ? nil : MainDeadline(owner: "Resources.card", workClass: .visible, scheduler: deadlines)
        work = source == nil ? nil : deadlines.work
    }

    /// Starts sampling `target` (or keeps sampling it) and sends every
    /// report to `onUpdate`. Opening another target restarts from zero.
    public func open(_ target: ResourceTarget, onUpdate: @escaping Update) {
        if self.target == target {
            self.onUpdate = onUpdate
            if let report { onUpdate(report) }
            return
        }
        close()
        guard source != nil, timer != nil else { return }
        self.onUpdate = onUpdate
        self.target = target
        take(generation)
    }

    /// Stops: cancels the pending deadline and the running sample, and drops every sample.
    public func close() {
        timer?.cancel()
        sampling?.cancel()
        sampling = nil
        generation &+= 1
        target = nil
        latest = nil
        report = nil
        onUpdate = nil
        sampleCount = 0
    }

    /// Starts one sample of start `generation`; its report lands as one visible task.
    private func take(_ generation: UInt64) {
        guard generation == self.generation, let target, let work else { return }
        // task-owner: stored in sampling; close() cancels it, and a stale generation lands nothing
        sampling = Task { @concurrent [weak self] in
            guard let set = await self?.read(target, generation), !Task.isCancelled else { return }
            // node-free: the card samples only while it shows, and close() drops a late report
            work.postFromAnyThread(.visible, owner: "Resources.card") { [weak self] in self?.land(set, generation) }
        }
    }

    /// The source's sample of `target`, or nil when the card moved on (its main-actor resolution runs here).
    private func read(_ target: ResourceTarget, _ generation: UInt64) async -> ResourceSampleSet? {
        guard generation == self.generation, let source else { return nil }
        return await source.sample(target)
    }

    private func land(_ set: ResourceSampleSet, _ generation: UInt64) {
        guard generation == self.generation else { return }
        let report = ResourceAggregator.report(current: set, previous: latest)
        latest = set
        sampleCount += 1
        self.report = report
        onUpdate?(report)
        timer?.schedule(after: interval) { [weak self] in self?.take(generation) }
    }
}

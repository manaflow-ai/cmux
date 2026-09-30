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
/// one-shot ``DemandTimer`` deadline armed after the previous sample
/// finished, so nothing runs once ``close()`` is called and nothing ever
/// runs while no card is open.
@MainActor
public final class ResourceCardSampler {
    public typealias Update = @MainActor (ResourceReport) -> Void

    public let interval: Duration
    private let timer: DemandTimer
    private weak var source: (any ResourceSampleSource)?
    private var generation: UInt64 = 0
    private var onUpdate: Update?
    private var latest: ResourceSampleSet?
    public private(set) var target: ResourceTarget?
    /// The last report, for a card that appears after sampling started.
    public private(set) var report: ResourceReport?
    /// Samples taken since the card opened (tests, diagnostics).
    public private(set) var sampleCount = 0

    public init(source: (any ResourceSampleSource)?, interval: Duration = .seconds(1),
                timer: DemandTimer = DemandTimer(owner: "Resources.card")) {
        self.source = source
        self.interval = interval
        self.timer = timer
    }

    public var isOpen: Bool { target != nil }
    /// True while the next sample's deadline is pending.
    public var isScheduled: Bool { timer.isScheduled }

    public func setSource(_ source: (any ResourceSampleSource)?) {
        guard source !== self.source else { return }
        close()
        self.source = source
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
        guard source != nil else { return }
        self.onUpdate = onUpdate
        self.target = target
        let generation = generation
        Task { await self.take(generation) }
    }

    /// Replaces the receiver of reports without restarting.
    public func setUpdate(_ onUpdate: Update?) {
        self.onUpdate = onUpdate
        if let onUpdate, let report { onUpdate(report) }
    }

    /// Stops: cancels the pending deadline and drops every sample.
    public func close() {
        timer.cancel()
        generation &+= 1
        target = nil
        latest = nil
        report = nil
        onUpdate = nil
        sampleCount = 0
    }

    private func take(_ generation: UInt64) async {
        guard generation == self.generation, let target, let source else { return }
        let set = await source.sample(target)
        guard generation == self.generation else { return }
        let report = ResourceAggregator.report(current: set, previous: latest)
        latest = set
        sampleCount += 1
        self.report = report
        onUpdate?(report)
        timer.schedule(after: interval) { @MainActor [weak self] in
            await self?.take(generation)
        }
    }
}

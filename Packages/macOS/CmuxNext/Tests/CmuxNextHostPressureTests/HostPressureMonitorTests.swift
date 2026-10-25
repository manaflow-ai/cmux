import Foundation
import os
@testable import CmuxNextHostPressure
import Testing

/// A scripted host: acpmux's verdict when it has one, else the local one.
private actor ScriptedSource: HostPressureSource {
    var shared: HostBudgetVerdict?
    var local = ScriptedSource.verdict()
    private(set) var localReads = 0

    static func verdict(load: Double = 2, pressure: HostMemoryPressure = .normal, swap: Double = 0) -> HostBudgetVerdict {
        HostBudgetVerdict(host: "gray", cores: 12, load1: load, pressure: pressure, availableRAMFraction: 0.5, swapMBPerMin: swap)
    }

    func set(local: HostBudgetVerdict) { self.local = local }
    func set(shared: HostBudgetVerdict?) { self.shared = shared }
    func acpmuxVerdict() -> HostBudgetVerdict? { shared }
    func localVerdict() -> HostBudgetVerdict {
        localReads += 1
        return local
    }
}

/// The app's shared memory pressure feed as the test drives it: `send(_:)` calls every subscriber.
private final class Feed: Sendable {
    private let handlers = OSAllocatedUnfairLock<[UUID: @Sendable (HostMemoryPressure) -> Void]>(initialState: [:])

    var subscription: HostPressureMonitor.MemoryPressureSubscription {
        { [handlers] handler in
            let id = UUID()
            handlers.withLock { $0[id] = handler }
            return { handlers.withLock { $0[id] = nil } }
        }
    }

    var subscribers: Int { handlers.withLock { $0.count } }

    func send(_ pressure: HostMemoryPressure) {
        for handler in handlers.withLock({ Array($0.values) }) { handler(pressure) }
    }
}

/// A feed that never changes, for tests that drive `memoryPressureChanged(_:)` themselves.
private let noFeed: HostPressureMonitor.MemoryPressureSubscription = { _ in {} }

@MainActor private final class Delivered {
    var levels: [HostPressureLevel] = []
}

/// The main-actor hops the monitor asked for, held until the test runs them.
private final class Held: Sendable {
    private let work = OSAllocatedUnfairLock<[@MainActor @Sendable () -> Void]>(initialState: [])
    func add(_ item: @escaping @MainActor @Sendable () -> Void) { work.withLock { $0.append(item) } }
    func take() -> [@MainActor @Sendable () -> Void] { work.withLock { items in defer { items = [] }; return items } }
}

/// The monitor escalates normal, warning, critical and back, telling the main
/// actor only when the level changes, and stops cleanly.
struct HostPressureMonitorTests {
    private func changes() -> (AsyncStream<HostPressureLevel>, HostPressureMonitor.Change) {
        let (stream, continuation) = AsyncStream<HostPressureLevel>.makeStream()
        return (stream, { level, _ in continuation.yield(level) })
    }

    @Test func itEscalatesAndCalmsDown() async {
        let source = ScriptedSource()
        let monitor = HostPressureMonitor(source: source, memoryPressure: noFeed, calmSamples: 2, ticks: false)
        let (stream, onChange) = changes()
        var levels = stream.makeAsyncIterator()
        await monitor.start(onChange: onChange)

        await monitor.read()
        #expect(await monitor.level == .normal)
        await source.set(local: ScriptedSource.verdict(load: 10))
        await monitor.read()
        #expect(await levels.next() == .warning)
        await monitor.memoryPressureChanged(.critical)
        #expect(await levels.next() == .critical)

        // The normal event is one calm sample (the load still warns), the next read the second.
        await monitor.memoryPressureChanged(.normal)
        #expect(await monitor.level == .critical)
        await source.set(local: ScriptedSource.verdict())
        await monitor.read()
        #expect(await levels.next() == .normal)
        await monitor.stop()
    }

    /// A start whose caller already stopped wanting it (checked on the actor) starts nothing.
    @Test func aStartNoLongerWantedStartsNothing() async {
        let monitor = HostPressureMonitor(source: ScriptedSource(), memoryPressure: noFeed)
        await monitor.start(while: { false }) { _, _ in }
        #expect(await !monitor.isRunning)
        await monitor.start(while: { true }) { _, _ in }
        #expect(await monitor.isRunning)
        await monitor.stop()
        #expect(await !monitor.isRunning)
    }

    @Test func acpmuxsVerdictWinsOverTheLocalOne() async {
        let source = ScriptedSource()
        await source.set(shared: ScriptedSource.verdict(load: 13, swap: 100))
        let monitor = HostPressureMonitor(source: source, memoryPressure: noFeed, ticks: false)
        await monitor.start { _, _ in }
        await monitor.read()
        #expect(await monitor.level == .critical)
        #expect(await source.localReads == 0)
        await monitor.stop()
    }

    @Test func theEventPressureBeatsTheSampledOne() async {
        let source = ScriptedSource()
        let monitor = HostPressureMonitor(source: source, memoryPressure: noFeed, ticks: false)
        await monitor.start { _, _ in }
        await monitor.memoryPressureChanged(.warn)
        await monitor.read()
        #expect(await monitor.verdict?.pressure == .warn)
        #expect(await monitor.level == .warning)
        await monitor.stop()
    }

    @Test func aStoppedMonitorAppliesNothing() async {
        let source = ScriptedSource()
        await source.set(local: ScriptedSource.verdict(pressure: .critical))
        let monitor = HostPressureMonitor(source: source, memoryPressure: noFeed, ticks: false)
        await monitor.start { _, _ in }
        await monitor.stop()
        await monitor.read()
        await monitor.memoryPressureChanged(.critical)
        #expect(await monitor.level == .normal)
        #expect(await !monitor.isRunning)
    }

    /// A level change still waiting for the main actor is dropped once stop() ends its run,
    /// and delivered when the run goes on.
    @MainActor @Test(arguments: [true, false]) func aChangeQueuedBeforeStopIsDropped(stops: Bool) async {
        let source = ScriptedSource()
        await source.set(local: ScriptedSource.verdict(pressure: .critical))
        let held = Held()
        let monitor = HostPressureMonitor(source: source, memoryPressure: noFeed, ticks: false) { held.add($0) }
        let delivered = Delivered()
        await monitor.start { level, _ in delivered.levels.append(level) }
        await monitor.read()
        if stops { await monitor.stop() }
        let queued = held.take()
        #expect(queued.count == 1)
        queued.forEach { $0() }
        #expect(delivered.levels == (stops ? [] : [.critical]))
        await monitor.stop()
    }

    /// A hop from a run that stop() ended applies nothing to the next run.
    @Test func aHopFromAnEndedRunIsIgnored() async {
        let source = ScriptedSource()
        let monitor = HostPressureMonitor(source: source, memoryPressure: noFeed, ticks: false)
        await monitor.start { _, _ in }
        let ended = await monitor.generation
        await monitor.stop()
        await monitor.start { _, _ in }
        await monitor.read()
        await monitor.memoryPressureChanged(.critical, generation: ended)
        await source.set(local: ScriptedSource.verdict(pressure: .critical))
        await monitor.read(generation: ended)
        #expect(await monitor.level == .normal)
        await monitor.memoryPressureChanged(.critical, generation: await monitor.generation)
        #expect(await monitor.level == .critical)
        await monitor.stop()
    }

    /// The monitor reads memory pressure from the shared feed (no kernel source of its own):
    /// one subscription per run, a change reaches the level, and stop() ends the subscription.
    @Test func theSharedFeedDrivesThePressureUntilStop() async {
        let feed = Feed()
        let monitor = HostPressureMonitor(source: ScriptedSource(), memoryPressure: feed.subscription, ticks: false)
        let (stream, onChange) = changes()
        var levels = stream.makeAsyncIterator()
        #expect(feed.subscribers == 0)
        await monitor.start(onChange: onChange)
        await monitor.start(onChange: onChange)
        #expect(feed.subscribers == 1)

        await monitor.read()
        feed.send(.critical)
        #expect(await levels.next() == .critical)
        #expect(await monitor.verdict?.pressure == .critical)

        await monitor.stop()
        #expect(feed.subscribers == 0)
        feed.send(.warn)
        #expect(await monitor.level == .normal)
    }

    /// A restarted monitor subscribes again and applies the new run's changes.
    @Test func aRestartSubscribesAgain() async {
        let feed = Feed()
        let monitor = HostPressureMonitor(source: ScriptedSource(), memoryPressure: feed.subscription, ticks: false)
        let (stream, onChange) = changes()
        var levels = stream.makeAsyncIterator()
        await monitor.start { _, _ in }
        await monitor.stop()
        #expect(feed.subscribers == 0)
        await monitor.start(onChange: onChange)
        #expect(feed.subscribers == 1)
        await monitor.read()
        feed.send(.warn)
        #expect(await levels.next() == .warning)
        await monitor.stop()
        #expect(feed.subscribers == 0)
    }

    @Test func theTimerAndTheFeedStartAndStop() async {
        let feed = Feed()
        let monitor = HostPressureMonitor(source: ScriptedSource(), memoryPressure: feed.subscription, interval: .seconds(3600))
        await monitor.start { _, _ in }
        #expect(await monitor.isRunning)
        #expect(feed.subscribers == 1)
        await monitor.stop()
        #expect(await !monitor.isRunning)
        #expect(feed.subscribers == 0)
    }
}

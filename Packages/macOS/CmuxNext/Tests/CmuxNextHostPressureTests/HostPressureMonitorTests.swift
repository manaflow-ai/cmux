import CmuxNextCompat
import Foundation
@testable import CmuxNextHostPressure
import Testing

/// A scripted host: acpmux's verdict when it has one, else the local one.
private actor ScriptedSource: HostPressureSource {
    var shared: HostBudgetVerdict?
    var local = ScriptedSource.verdict()
    private(set) var localReads = 0
    /// The memory pressure the monitor passed to the last local read.
    private(set) var localPressure: HostMemoryPressure?

    static func verdict(load: Double = 2, pressure: HostMemoryPressure = .normal, swap: Double = 0) -> HostBudgetVerdict {
        HostBudgetVerdict(host: "gray", cores: 12, load1: load, pressure: pressure, availableRAMFraction: 0.5, swapMBPerMin: swap)
    }

    func set(local: HostBudgetVerdict) { self.local = local }
    func set(shared: HostBudgetVerdict?) { self.shared = shared }
    func acpmuxVerdict() -> HostBudgetVerdict? { shared }
    func localVerdict(pressure: HostMemoryPressure) -> HostBudgetVerdict {
        localReads += 1
        localPressure = pressure
        return local
    }
}

/// The app's shared memory pressure feed as the test drives it: `send(_:)` sets its level and calls
/// every subscriber.
private final class Feed: Sendable {
    private struct State {
        var handlers: [UUID: @Sendable (HostMemoryPressure) -> Void] = [:]
        var level: HostMemoryPressure
    }

    private let state: Mutex<State>

    init(level: HostMemoryPressure = .normal) {
        state = Mutex(State(level: level))
    }

    var subscription: HostPressureMonitor.MemoryPressureSubscription {
        { [self] handler in
            let id = UUID()
            let level = self.state.withLock { state in
                state.handlers[id] = handler
                return state.level
            }
            return (level, { self.state.withLock { $0.handlers[id] = nil } })
        }
    }

    var subscribers: Int { state.withLock { $0.handlers.count } }

    func send(_ pressure: HostMemoryPressure) {
        let handlers = state.withLock { state in
            state.level = pressure
            return Array(state.handlers.values)
        }
        for handler in handlers { handler(pressure) }
    }
}

/// A feed that stays normal, for tests that drive `memoryPressureChanged(_:)` themselves.
private let noFeed: HostPressureMonitor.MemoryPressureSubscription = { _ in (.normal, {}) }

@MainActor private final class Delivered {
    var levels: [HostPressureLevel] = []
}

/// The main-actor hops the monitor asked for, held until the test runs them.
private final class Held: Sendable {
    private let work = Mutex<[@MainActor @Sendable () -> Void]>([])
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

    /// The feed's level is the only memory level: the local read gets it, and it beats a level
    /// in the source's verdict.
    @Test func theFeedsLevelBeatsTheSourcesOne() async {
        let source = ScriptedSource()
        await source.set(local: ScriptedSource.verdict(pressure: .critical))
        let monitor = HostPressureMonitor(source: source, memoryPressure: noFeed, ticks: false)
        await monitor.start { _, _ in }
        await monitor.memoryPressureChanged(.warn)
        await monitor.read()
        #expect(await source.localPressure == .warn)
        #expect(await monitor.verdict?.pressure == .warn)
        #expect(await monitor.level == .warning)
        await monitor.stop()
    }

    /// A run starts at the feed's level now, before any change: critical while the monitor was
    /// stopped, with no change since, is critical on the first read.
    @Test func aRunStartsAtTheFeedsCurrentLevel() async {
        let feed = Feed(level: .critical)
        let source = ScriptedSource()
        let monitor = HostPressureMonitor(source: source, memoryPressure: feed.subscription, ticks: false)
        await monitor.start { _, _ in }
        await monitor.read()
        #expect(await source.localPressure == .critical)
        #expect(await monitor.verdict?.pressure == .critical)
        #expect(await monitor.level == .critical)
        await monitor.stop()
    }

    /// The feed's changes apply in the order it sent them: a burst of changes reaches the main
    /// actor as the same sequence of levels, and the last one stays.
    @Test(.timeLimit(.minutes(1))) func theFeedsChangesApplyInOrder() async {
        let feed = Feed()
        let monitor = HostPressureMonitor(source: ScriptedSource(), memoryPressure: feed.subscription, calmSamples: 1, ticks: false)
        let (stream, onChange) = changes()
        var levels = stream.makeAsyncIterator()
        await monitor.start(onChange: onChange)
        await monitor.read()

        // Every change fits the reader's buffer, so each one is delivered.
        let cycles = HostPressureMonitor.pendingPressureChanges / 3
        for _ in 0 ..< cycles {
            feed.send(.warn)
            feed.send(.critical)
            feed.send(.normal)
        }
        var received: [HostPressureLevel] = []
        for _ in 0 ..< cycles * 3 {
            guard let level = await levels.next() else { break }
            received.append(level)
        }
        #expect(received == Array(repeating: [HostPressureLevel.warning, .critical, .normal], count: cycles).flatMap { $0 })
        #expect(await monitor.verdict?.pressure == .normal)
        await monitor.stop()
    }

    @Test func aStoppedMonitorAppliesNothing() async {
        let source = ScriptedSource()
        await source.set(local: ScriptedSource.verdict(load: 13, swap: 100))
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
        await source.set(local: ScriptedSource.verdict(load: 13, swap: 100))
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
        await source.set(local: ScriptedSource.verdict(load: 13, swap: 100))
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

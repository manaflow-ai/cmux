import Foundation
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

@MainActor private final class Delivered {
    var levels: [HostPressureLevel] = []
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
        let monitor = HostPressureMonitor(source: source, calmSamples: 2, ticks: false)
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

    @Test func acpmuxsVerdictWinsOverTheLocalOne() async {
        let source = ScriptedSource()
        await source.set(shared: ScriptedSource.verdict(load: 13, swap: 100))
        let monitor = HostPressureMonitor(source: source, ticks: false)
        await monitor.start { _, _ in }
        await monitor.read()
        #expect(await monitor.level == .critical)
        #expect(await source.localReads == 0)
        await monitor.stop()
    }

    @Test func theEventPressureBeatsTheSampledOne() async {
        let source = ScriptedSource()
        let monitor = HostPressureMonitor(source: source, ticks: false)
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
        let monitor = HostPressureMonitor(source: source, ticks: false)
        await monitor.start { _, _ in }
        await monitor.stop()
        await monitor.read()
        await monitor.memoryPressureChanged(.critical)
        #expect(await monitor.level == .normal)
        #expect(await !monitor.isRunning)
    }

    /// A level change queued for a busy main actor is dropped once stop() ends its run.
    @MainActor @Test func aChangeQueuedBeforeStopIsDropped() async {
        let source = ScriptedSource()
        await source.set(local: ScriptedSource.verdict(pressure: .critical))
        let monitor = HostPressureMonitor(source: source, ticks: false)
        let delivered = Delivered()
        await monitor.start { level, _ in delivered.levels.append(level) }
        let done = DispatchSemaphore(value: 0)
        // task-owner: the test; it reads (queueing a delivery behind the blocked main actor), then stops
        Task.detached {
            await monitor.read()
            await monitor.stop()
            done.signal()
        }
        // concurrency-allow: the test blocks the main actor on purpose so the delivery waits behind stop()
        #expect(done.wait(timeout: .now() + 30) == .success)
        // The main queue is FIFO: this runs after the queued delivery.
        await Task { @MainActor in }.value
        #expect(delivered.levels.isEmpty)
    }

    /// A hop from a run that stop() ended applies nothing to the next run.
    @Test func aHopFromAnEndedRunIsIgnored() async {
        let source = ScriptedSource()
        let monitor = HostPressureMonitor(source: source, ticks: false)
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

    @Test func theRealSourcesStartAndStop() async {
        let monitor = HostPressureMonitor(source: ScriptedSource(), interval: .seconds(3600))
        await monitor.start { _, _ in }
        #expect(await monitor.isRunning)
        await monitor.stop()
        #expect(await !monitor.isRunning)
    }
}

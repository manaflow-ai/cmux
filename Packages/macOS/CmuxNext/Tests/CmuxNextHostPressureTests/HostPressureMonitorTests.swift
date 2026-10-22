import Foundation
@testable import CmuxNextHostPressure
import Testing

/// A scripted host: acpmux's verdict when it has one, else the local one.
private actor ScriptedSource: HostPressureSource {
    var shared: HostBudgetVerdict?
    var local = ScriptedSource.verdict()
    private(set) var localReads = 0

    static func verdict(load: Double = 2, pressure: HostMemoryPressure = .normal, swap: Double = 0) -> HostBudgetVerdict {
        HostBudgetVerdict(host: "gray", cores: 12, load1: load, loadLimit: 12, pressure: pressure, swapMBPerMin: swap, swapLimit: 64)
    }

    func set(local: HostBudgetVerdict) { self.local = local }
    func set(shared: HostBudgetVerdict?) { self.shared = shared }
    func acpmuxVerdict() -> HostBudgetVerdict? { shared }
    func localVerdict() -> HostBudgetVerdict {
        localReads += 1
        return local
    }
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

    @Test func theRealSourcesStartAndStop() async {
        let monitor = HostPressureMonitor(source: ScriptedSource(), interval: .seconds(3600))
        await monitor.start { _, _ in }
        #expect(await monitor.isRunning)
        await monitor.stop()
        #expect(await !monitor.isRunning)
    }
}

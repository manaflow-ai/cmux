@testable import CmuxNextHostPressure
import CmuxNextTrace
import Testing

/// A host whose local verdict the test sets.
private actor SetSource: HostPressureSource {
    var local = HostBudgetVerdict(host: "gray", cores: 12, load1: 2, pressure: .normal, availableRAMFraction: 0.5, swapMBPerMin: 0)

    func set(load: Double) {
        local = HostBudgetVerdict(host: "gray", cores: 12, load1: load, pressure: .normal, availableRAMFraction: 0.5, swapMBPerMin: 0)
    }

    func acpmuxVerdict() -> HostBudgetVerdict? { nil }
    func localVerdict(pressure: HostMemoryPressure) -> HostBudgetVerdict { local }
}

/// Each host pressure level change writes a `host.pressure` counter and a `host.pressure.change` instant into the
/// black box's `hang` category (p09-observability task 121); a verdict that keeps the level writes nothing.
struct HostPressureTraceTests {
    /// The `host.pressure*` records in `ring`, as (name, phase, arg0, arg1).
    private static func pressureRecords(_ ring: TraceRing) throws -> [(String, TraceRecord.Phase?, UInt64, UInt64)] {
        let image = try #require(ring.decodedImage())
        return image.records.compactMap { record in
            guard let name = image.name(record.name), name.hasPrefix("host.pressure") else { return nil }
            return (name, record.phase, record.arg0, record.arg1)
        }
    }

    @Test func eachLevelChangeWritesACounterAndAnInstant() async throws {
        let ring = TraceRing(records: 1_024, role: .app)
        let runtime = TraceRuntime(role: .app)
        _ = runtime.attach(ring)
        runtime.setCategories(.blackBox)
        let source = SetSource()
        let monitor = HostPressureMonitor(source: source, memoryPressure: { _ in (.normal, {}) }, calmSamples: 1, ticks: false,
                                          deliver: { _ in }, trace: runtime)
        await monitor.start { _, _ in }

        await monitor.read()  // normal stays normal: nothing
        await source.set(load: 10)
        await monitor.read()  // warning
        await monitor.read()  // still warning: nothing
        await monitor.memoryPressureChanged(.critical)  // critical
        await monitor.stop()

        let records = try Self.pressureRecords(ring)
        #expect(records.count == 4)
        let counters = records.filter { $0.0 == "host.pressure" }
        let instants = records.filter { $0.0 == "host.pressure.change" }
        #expect(counters.map(\.1) == [.counter, .counter])
        #expect(counters.map(\.2) == [1, 2])
        #expect(instants.map(\.1) == [.instant, .instant])
        #expect(instants.map(\.2) == [1, 2])
        #expect(instants.first.map { $0.3 & 0xFF } == 0, "the first change came from normal")
        #expect(instants.last.map { $0.3 & 0xFF } == 1, "the second from warning")
        #expect(instants.last.map { $0.3 >> 8 & 0xFF } == 2, "under critical memory pressure")
    }

    @Test func withTheHangCategoryOffNothingIsWritten() async throws {
        let ring = TraceRing(records: 1_024, role: .app)
        let runtime = TraceRuntime(role: .app)
        _ = runtime.attach(ring)
        runtime.setCategories([.action])
        let monitor = HostPressureMonitor(source: SetSource(), memoryPressure: { _ in (.normal, {}) }, ticks: false,
                                          deliver: { _ in }, trace: runtime)
        await monitor.start { _, _ in }
        await monitor.memoryPressureChanged(.critical)
        await monitor.read()
        await monitor.stop()
        #expect(try Self.pressureRecords(ring).isEmpty)
    }

    @Test func theCategoryIsTheHangBit() {
        #expect(HostPressureMonitor.hangCategoryBit == 7)
    }
}

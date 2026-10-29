import CmuxNextCompat
import CmuxNextMemory
import Testing

/// A pool of spares follows the coordinator's level by Chrome's spare rule
/// (`content/browser/renderer_host/spare_render_process_host_manager_impl.cc`): no spare at warning
/// or critical, no refill until normal, and at normal one spare in every Memory Saver mode (the
/// reviewed design dropped it at the conservative 75 % share).
@MainActor @Suite struct SpareMemoryConsumerTests {
    /// A pool of at most one spare that records what the consumer asked of it.
    @MainActor final class Pool {
        var spares = 0
        private(set) var drops = 0
        private(set) var refills = 0
        private(set) var holds = 0

        func hold() {
            holds += 1
        }

        func drop() {
            drops += 1
            spares = 0
        }

        func refill() {
            refills += 1
        }
    }

    private struct Harness {
        let source: ManualMemoryPressureSource
        let pressure: MemoryPressureEvents
        let coordinator: MemoryCoordinator
        let slicer: ManualSlicer
        let pool: Pool
        let consumer: SpareMemoryConsumer
    }

    private func harness(mode: MemorySaverMode, initial: MemoryPressureLevel = .normal) -> Harness {
        let clock = ManualClock()
        let source = ManualMemoryPressureSource(initial: initial)
        let slicer = ManualSlicer(clock: clock)
        let pressure = MemoryPressureEvents(source: source)
        let coordinator = MemoryCoordinator(pressure: pressure, mode: mode, slicer: slicer, clock: clock)
        let pool = Pool()
        let consumer = SpareMemoryConsumer(
            name: "test-spare", registry: coordinator, spares: { pool.spares },
            drop: { pool.drop() }, refill: { pool.refill() })
        return Harness(source: source, pressure: pressure, coordinator: coordinator, slicer: slicer, pool: pool, consumer: consumer)
    }

    @Test(arguments: MemorySaverMode.allCases)
    func normalKeepsOneSpareInEveryMode(mode: MemorySaverMode) {
        let test = harness(mode: mode)
        test.pool.spares = 1
        #expect(test.consumer.allowsSpares, "\(mode) at normal refused a spare")
        #expect(test.coordinator.limit(for: SpareMemoryConsumer.traits) == .default)
        test.slicer.drain()
        #expect(test.pool.spares == 1 && test.pool.drops == 0, "\(mode) at normal dropped the spare")
    }

    /// The case the reviewed design got wrong: medium mode at normal pressure keeps its spare, and a
    /// mode change at normal leaves it too.
    @Test func mediumModeAtNormalKeepsTheSpare() {
        let test = harness(mode: .medium)
        test.pool.spares = 1
        test.coordinator.mode = .aggressive
        test.coordinator.mode = .medium
        test.slicer.drain()
        #expect(test.consumer.allowsSpares)
        #expect(test.pool.spares == 1 && test.pool.drops == 0)
    }

    @Test func aWarningDropsTheSpareAndNothingRefillsUntilNormal() {
        let test = harness(mode: .medium)
        test.pool.spares = 1
        test.source.send(.warning)
        #expect(test.pool.drops == 1, "a warning must drop the spare in its own turn")
        #expect(test.pool.spares == 0)
        #expect(!test.consumer.allowsSpares, "no spare may be made or parked at warning")
        test.slicer.drain()
        #expect(test.pool.refills == 0, "no refill at warning")

        test.source.send(.critical)
        #expect(!test.consumer.allowsSpares)
        #expect(test.pool.refills == 0, "no refill at critical")

        test.source.send(.normal)
        #expect(test.consumer.allowsSpares)
        #expect(test.pool.refills == 1, "back at normal the pool is asked once to refill")
        test.source.send(.normal)
        #expect(test.pool.refills == 1, "a repeated level asks nothing")
    }

    /// A pool that closes only at critical (Chromium's spare windows) keeps its
    /// untaken spare at warning, as Chrome keeps its spare renderer, and only holds new ones; critical
    /// closes it, and a later warning holds again without a second close.
    @Test func closingAtCriticalHoldsAtWarningAndClosesAtCritical() {
        let source = ManualMemoryPressureSource()
        let pressure = MemoryPressureEvents(source: source)
        let coordinator = MemoryCoordinator(pressure: pressure, mode: .medium, slicer: ManualSlicer(clock: ManualClock()))
        let pool = Pool()
        let consumer = SpareMemoryConsumer(
            name: "test-spare-windows", registry: coordinator, closing: .atCritical, spares: { pool.spares },
            hold: { pool.hold() }, drop: { pool.drop() }, refill: { pool.refill() })
        pool.spares = 1

        source.send(.warning)
        #expect(pool.holds == 1 && pool.drops == 0, "a warning closed the untaken spare")
        #expect(pool.spares == 1)
        #expect(!consumer.allowsSpares, "a new spare was allowed at warning")

        source.send(.critical)
        #expect(pool.drops == 1 && pool.spares == 0, "critical must close the untaken spare")

        source.send(.warning)
        #expect(pool.holds == 2 && pool.drops == 1)
        source.send(.normal)
        #expect(consumer.allowsSpares)
        #expect(pool.refills == 1)
        withExtendedLifetime((pressure, coordinator)) {}
    }

    @Test func theClosingLevels() {
        let anyPressure = SpareMemoryConsumer.Closing.atAnyPressure, onlyCritical = SpareMemoryConsumer.Closing.atCritical
        #expect([MemoryPressureLevel.normal, .warning, .critical].map(anyPressure.closes(at:)) == [false, true, true])
        #expect([MemoryPressureLevel.normal, .warning, .critical].map(onlyCritical.closes(at:)) == [false, false, true])
    }

    /// A pool made under pressure learns it before its consumer's init returns: it never warms.
    @Test func aPoolMadeUnderPressureAllowsNoSpare() {
        let test = harness(mode: .off, initial: .warning)
        #expect(!test.consumer.allowsSpares)
        #expect(test.pool.refills == 0)
    }

    @Test func theDebugOverrideActsAsTheKernelLevel() {
        let test = harness(mode: .medium)
        test.coordinator.pressureOverride = .warning
        #expect(!test.consumer.allowsSpares)
        test.coordinator.pressureOverride = nil
        #expect(test.consumer.allowsSpares)
        #expect(test.pool.refills == 1)
    }

    @Test func cancelStopsTheLevels() {
        let test = harness(mode: .medium)
        test.consumer.cancel()
        test.source.send(.warning)
        #expect(test.pool.drops == 0)
        #expect(test.consumer.allowsSpares)
    }

    @Test func theReportShowsNoSpareAsEmptyAndASpareAsUnknown() {
        let test = harness(mode: .medium)
        #expect(test.consumer.memoryUsage == .empty)
        test.pool.spares = 1
        #expect(test.consumer.memoryUsage == nil)
    }

    @Test func traitsAreAMediumExpensiveUnmanagedSpare() {
        let traits = SpareMemoryConsumer.traits
        #expect(traits.estimatedUsage == .medium)
        #expect(traits.recreateCost == .expensive)
        #expect(!traits.isManaged, "a mode share must never scale a spare")
    }
}

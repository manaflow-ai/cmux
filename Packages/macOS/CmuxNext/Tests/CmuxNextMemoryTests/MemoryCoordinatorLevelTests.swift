import CmuxNextCompat
import CmuxNextMemory
import Testing

/// A ``MemoryLevelConsumer`` (browser hibernation, p07-memory task 017) gets the coordinator's
/// level: at registration, then once per change of level, the debug override included, and never
/// after its registration is cancelled. A plain consumer gets no level calls.
@MainActor @Suite struct MemoryCoordinatorLevelTests {
    @MainActor final class LevelConsumer: MemoryLevelConsumer {
        private(set) var levels: [MemoryPressureLevel] = []
        private(set) var limits: [Int] = []

        func memoryLevelDidChange(_ level: MemoryPressureLevel) { levels.append(level) }
        func updateMemoryLimit(_ limit: MemoryLimit) { limits.append(limit.percent) }
        func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress { .done }
        var memoryUsage: MemoryUsage? { nil }
    }

    static let lossyTraits = MemoryConsumerTraits(
        estimatedUsage: .large, dataAccess: .reads, retention: .lossy, recreateCost: .expensive,
        releaseCPUCost: .high, isStateful: false, supportsMemoryLimit: false)

    @Test func levelConsumerGetsTheLevelAtRegistrationAndOnEachChange() {
        let clock = ManualClock()
        let source = ManualMemoryPressureSource(initial: .warning)
        let pressure = MemoryPressureEvents(source: source)
        let coordinator = MemoryCoordinator(pressure: pressure, slicer: ManualSlicer(clock: clock), clock: clock)
        let consumer = LevelConsumer()
        let registration = MemoryConsumerRegistration(
            name: "planner", traits: Self.lossyTraits, consumer: consumer, registry: coordinator)
        #expect(consumer.levels == [.warning], "a new level consumer gets the current level before its registration returns")
        // A lossy consumer's limit stays 100 % at warning: only the level tells it about warning.
        #expect(consumer.limits == [100])

        source.send(.warning)
        #expect(consumer.levels == [.warning], "a repeated level makes no call")
        source.send(.critical)
        #expect(consumer.levels == [.warning, .critical])
        #expect(consumer.limits == [100, 0])

        coordinator.pressureOverride = .normal
        #expect(consumer.levels == [.warning, .critical, .normal], "the debug override reaches it as a level")

        registration.cancel()
        coordinator.pressureOverride = .critical
        #expect(consumer.levels == [.warning, .critical, .normal], "no level after the registration is cancelled")
        withExtendedLifetime((pressure, coordinator)) {}
    }
}

import CmuxNextCompat
import CmuxNextMemory
import Testing

/// The `memory.saver` mode reaches the planners that time discards by it: a
/// ``MemorySaverModeConsumer`` gets the mode at registration and once per change, after the new
/// limits, and never after its registration is cancelled. A repeated mode makes no call, and a plain
/// consumer gets none.
@MainActor @Suite struct MemorySaverSettingCoordinatorTests {
    @MainActor final class ModeConsumer: MemorySaverModeConsumer {
        private(set) var modes: [MemorySaverMode] = []
        /// What the consumer saw, in order: `limit N` or `mode M`.
        private(set) var calls: [String] = []

        func memorySaverModeDidChange(_ mode: MemorySaverMode) {
            modes.append(mode)
            calls.append("mode \(mode.rawValue)")
        }

        func updateMemoryLimit(_ limit: MemoryLimit) { calls.append("limit \(limit.percent)") }
        func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress { .done }
        var memoryUsage: MemoryUsage? { nil }
    }

    /// A managed consumer with no data access, cheap to recreate: its limit follows the mode at warning.
    static let managedTraits = MemoryConsumerTraits(
        estimatedUsage: .medium, dataAccess: .none, retention: .lossless, recreateCost: .cheap,
        releaseCPUCost: .low, isStateful: true, supportsMemoryLimit: true)

    @Test func aModeConsumerGetsTheModeAtRegistrationAndOnEachChangeAfterTheLimits() {
        let clock = ManualClock()
        let source = ManualMemoryPressureSource(initial: .warning)
        let pressure = MemoryPressureEvents(source: source)
        let coordinator = MemoryCoordinator(pressure: pressure, mode: .conservative, slicer: ManualSlicer(clock: clock), clock: clock)
        let consumer = ModeConsumer()
        let registration = MemoryConsumerRegistration(
            name: "planner", traits: Self.managedTraits, consumer: consumer, registry: coordinator)
        #expect(consumer.modes == [.conservative], "a new mode consumer gets the current mode before its registration returns")

        coordinator.mode = .conservative
        #expect(consumer.modes == [.conservative], "a repeated mode makes no call")

        let before = consumer.calls.count
        coordinator.mode = .aggressive
        #expect(consumer.modes == [.conservative, .aggressive])
        let after = Array(consumer.calls.dropFirst(before))
        #expect(after.last == "mode aggressive", "the mode came before the new limit: \(after)")
        #expect(after.contains { $0.hasPrefix("limit ") }, "the warning limit did not follow the mode: \(after)")

        registration.cancel()
        coordinator.mode = .off
        #expect(consumer.modes == [.conservative, .aggressive], "no mode after the registration is cancelled")
        withExtendedLifetime((pressure, coordinator)) {}
    }

    @Test func aPlainConsumerGetsNoMode() {
        let clock = ManualClock()
        let pressure = MemoryPressureEvents(source: ManualMemoryPressureSource(initial: .normal))
        let coordinator = MemoryCoordinator(pressure: pressure, slicer: ManualSlicer(clock: clock), clock: clock)
        #expect(coordinator.mode == .medium, "medium is the default, the timeouts cmux shipped before the setting")
        let consumer = MemoryCoordinatorLevelTests.LevelConsumer()
        let registration = MemoryConsumerRegistration(
            name: "level-only", traits: MemoryCoordinatorLevelTests.lossyTraits, consumer: consumer, registry: coordinator)
        coordinator.mode = .aggressive
        #expect(consumer.levels == [.normal], "a mode change is no level change")
        withExtendedLifetime((pressure, coordinator, registration)) {}
    }
}

import CmuxNextCompat
import CmuxNextMemory
import Testing

/// p07-memory-051: the coordinator's vote in in-process Chromium's pressure aggregator is its level: the debug
/// override when set, else the cmux level from the kernel's events; normal (Chromium's none) once the override
/// clears to a normal kernel level. Observers hear each change of the level once, after the new limits.
@MainActor @Suite struct MemoryCoordinatorPressureVoteTests {
    @MainActor final class Votes {
        var levels: [MemoryPressureLevel] = []
    }

    @Test func oneVotePerOverrideChangeAndNoneWhenItClears() {
        let clock = ManualClock()
        let source = ManualMemoryPressureSource(initial: .normal)
        let pressure = MemoryPressureEvents(source: source)
        let coordinator = MemoryCoordinator(pressure: pressure, slicer: ManualSlicer(clock: clock), clock: clock)
        let votes = Votes()
        let observation = coordinator.observePressureVote { votes.levels.append($0) }
        #expect(coordinator.pressureVote == .normal, "a normal kernel level and no override: none")

        coordinator.pressureOverride = .critical
        #expect(votes.levels == [.critical])
        #expect(coordinator.level == .critical, "the limits took the override before the vote was told")

        source.send(.normal)
        #expect(votes.levels == [.critical], "a kernel normal event under the override leaves the vote held")
        #expect(coordinator.pressureVote == .critical)

        coordinator.pressureOverride = .critical
        #expect(votes.levels == [.critical], "a repeated override makes no vote")

        coordinator.pressureOverride = .warning
        coordinator.pressureOverride = nil
        #expect(votes.levels == [.critical, .warning, .normal], "clearing to a normal kernel level votes none")
        #expect(coordinator.pressureVote == .normal)
        withExtendedLifetime((pressure, coordinator, observation)) {}
    }

    @Test func oneVotePerKernelDrivenLevelChange() {
        let clock = ManualClock()
        let source = ManualMemoryPressureSource(initial: .warning)
        let pressure = MemoryPressureEvents(source: source)
        let coordinator = MemoryCoordinator(pressure: pressure, slicer: ManualSlicer(clock: clock), clock: clock)
        let votes = Votes()
        let observation = coordinator.observePressureVote { votes.levels.append($0) }
        #expect(coordinator.pressureVote == .warning, "without an override the vote is the cmux level")

        source.send(.critical)
        source.send(.critical)
        source.send(.normal)
        #expect(votes.levels == [.critical, .normal], "one vote per change of the level, none for a repeat")

        coordinator.pressureOverride = .normal
        coordinator.pressureOverride = nil
        #expect(votes.levels == [.critical, .normal], "an override equal to the level changes no vote")

        coordinator.pressureOverride = .warning
        source.send(.critical)
        #expect(votes.levels == [.critical, .normal, .warning], "the kernel does not move the level under an override")
        coordinator.pressureOverride = nil
        #expect(votes.levels == [.critical, .normal, .warning, .critical], "clearing votes the kernel's level")

        observation.cancel()
        coordinator.pressureOverride = .normal
        #expect(votes.levels.count == 4, "no vote after the registration is cancelled")
        withExtendedLifetime((pressure, coordinator)) {}
    }
}

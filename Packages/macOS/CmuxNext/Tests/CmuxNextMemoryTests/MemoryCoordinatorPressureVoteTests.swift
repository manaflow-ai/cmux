import CmuxNextCompat
import CmuxNextMemory
import Testing

/// p07-memory-051: the coordinator's vote in in-process Chromium's pressure aggregator is its debug override,
/// normal (Chromium's none) once the override clears. Observers hear each change of the vote once, after the new
/// limits; a kernel event changes no vote, because Chromium hears the kernel through its own platform voter.
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
        #expect(coordinator.pressureVote == .normal, "no override: no vote")

        coordinator.pressureOverride = .critical
        #expect(votes.levels == [.critical])
        #expect(coordinator.level == .critical, "the limits took the override before the vote was told")

        source.send(.normal)
        #expect(votes.levels == [.critical], "a kernel normal event leaves the vote held")
        #expect(coordinator.pressureVote == .critical)

        coordinator.pressureOverride = .critical
        #expect(votes.levels == [.critical], "a repeated override makes no vote")

        coordinator.pressureOverride = .warning
        coordinator.pressureOverride = nil
        #expect(votes.levels == [.critical, .warning, .normal], "clearing the override votes none")
        #expect(coordinator.pressureVote == .normal)
        withExtendedLifetime((pressure, coordinator, observation)) {}
    }

    @Test func kernelEventsAndAnOverrideOfNormalChangeNoVote() {
        let clock = ManualClock()
        let source = ManualMemoryPressureSource(initial: .warning)
        let pressure = MemoryPressureEvents(source: source)
        let coordinator = MemoryCoordinator(pressure: pressure, slicer: ManualSlicer(clock: clock), clock: clock)
        let votes = Votes()
        let observation = coordinator.observePressureVote { votes.levels.append($0) }

        source.send(.critical)
        source.send(.normal)
        coordinator.pressureOverride = .normal
        coordinator.pressureOverride = nil
        #expect(votes.levels.isEmpty, "the kernel's level is Chromium's own voter's; normal is no vote either way")

        observation.cancel()
        coordinator.pressureOverride = .critical
        #expect(votes.levels.isEmpty, "no vote after the registration is cancelled")
        withExtendedLifetime((pressure, coordinator)) {}
    }
}

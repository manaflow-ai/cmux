import CmuxNextCompat
import CmuxNextMemory
import Testing

/// The coordinator's vote in in-process Chromium's pressure aggregator is its level: the debug
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

    /// Override observers hear each change of the override, also one that keeps the level
    /// (which no level consumer and no vote hears), after the level it makes; a repeat is no change.
    @Test func overrideObserversHearChangesThatKeepTheLevel() {
        let clock = ManualClock()
        let source = ManualMemoryPressureSource(initial: .critical)
        let pressure = MemoryPressureEvents(source: source)
        let coordinator = MemoryCoordinator(pressure: pressure, slicer: ManualSlicer(clock: clock), clock: clock)
        let overrides = Overrides()
        let observation = coordinator.observePressureOverride { [unowned coordinator] in
            overrides.seen.append(Overrides.Seen(override: $0, level: coordinator.level))
        }
        let votes = Votes()
        let voteObservation = coordinator.observePressureVote { votes.levels.append($0) }

        coordinator.pressureOverride = .critical
        coordinator.pressureOverride = .critical
        coordinator.pressureOverride = nil
        #expect(overrides.seen == [.init(override: .critical, level: .critical), .init(override: nil, level: .critical)],
                "an override equal to the kernel's level, set and cleared, is heard once each")
        #expect(votes.levels.isEmpty, "the level never moved")

        coordinator.pressureOverride = .normal
        #expect(overrides.seen.last == .init(override: .normal, level: .normal), "heard after the level it makes")

        observation.cancel()
        coordinator.pressureOverride = nil
        #expect(overrides.seen.count == 3, "nothing heard after the registration is cancelled")
        withExtendedLifetime((pressure, coordinator, voteObservation)) {}
    }

    @MainActor final class Overrides {
        struct Seen: Equatable {
            var override: MemoryPressureLevel?
            var level: MemoryPressureLevel
        }

        var seen: [Seen] = []
    }
}

@testable import CmuxNextWakeups
import Testing

/// MainActorEnergyObservation: a main-actor writer's policy changes reach the
/// closure in the writer's turn, and none after a cancel or a release.
@MainActor @Suite("MainActorEnergyObservation")
struct MainActorEnergyObservationTests {
    @MainActor final class Seen {
        var policies: [EnergyPolicy] = []
    }

    @Test func changesReachTheClosureUntilCancelled() {
        let source = EnergyPolicySource()
        let seen = Seen()
        let observation = MainActorEnergyObservation(source) { seen.policies.append($0) }
        let saver = EnergyPolicy(saverReason: .setting)
        source.update(saver)
        #expect(seen.policies == [saver])
        observation.cancel()
        source.update(.normal)
        #expect(seen.policies == [saver])
        #expect(source.observerCount == 0)
    }

    @Test func aReleasedObservationStopsObserving() {
        let source = EnergyPolicySource()
        let seen = Seen()
        var observation: MainActorEnergyObservation? = MainActorEnergyObservation(source) { seen.policies.append($0) }
        #expect(source.observerCount == 1)
        observation = nil
        #expect(observation == nil && source.observerCount == 0)
        source.update(EnergyPolicy(saverReason: .setting))
        #expect(seen.policies.isEmpty)
    }
}

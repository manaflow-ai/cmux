import Testing
@testable import CmuxWorkspaces

@Suite struct RestoredProcessDetectionObservationTests {
    @Test func armedLifecycleStatePreservesUntilCleared() {
        var observation = RestoredProcessDetectionObservation()
        #expect(!observation.preserves())
        observation.arm()
        #expect(observation.preserves())
        observation.clear()
        #expect(!observation.preserves())
    }

    @Test func observationWaitsForTheRuntimeSpawnBeforeItsWindowStarts() {
        // A paced or unviewed restored terminal may spawn long after restore;
        // its command cannot have run, so the window must not start early.
        var observation = RestoredProcessDetectionObservation()
        observation.arm()
        let spawnedAt = SuspendingClock.now.advanced(by: .seconds(3_600))
        #expect(observation.preserves(at: spawnedAt))
        #expect(observation.recordRuntimeSpawn(at: spawnedAt))
        #expect(!observation.recordRuntimeSpawn(at: spawnedAt.advanced(by: .seconds(10))))
        let window = RestoredProcessDetectionObservation.observationWindow
        #expect(observation.preserves(at: spawnedAt.advanced(by: window - .seconds(1))))
        #expect(!observation.preserves(at: spawnedAt.advanced(by: window)))
    }

    @Test func aClearedObservationIgnoresALateSpawn() {
        var observation = RestoredProcessDetectionObservation()
        observation.arm()
        observation.clear()
        #expect(!observation.recordRuntimeSpawn())
        #expect(!observation.preserves())
    }
}

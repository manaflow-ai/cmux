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
        // `recordRuntimeSpawn` is mutating, so each result is read outside the test macros.
        let firstSpawn = observation.recordRuntimeSpawn(at: spawnedAt)
        let repeatedSpawn = observation.recordRuntimeSpawn(at: spawnedAt.advanced(by: .seconds(10)))
        #expect(firstSpawn)
        #expect(!repeatedSpawn)
        let window = RestoredProcessDetectionObservation.observationWindow
        #expect(observation.preserves(at: spawnedAt.advanced(by: window - .seconds(1))))
        #expect(!observation.preserves(at: spawnedAt.advanced(by: window)))
    }

    @Test func aClearedObservationIgnoresALateSpawn() {
        var observation = RestoredProcessDetectionObservation()
        observation.arm()
        observation.clear()
        let lateSpawn = observation.recordRuntimeSpawn()
        #expect(!lateSpawn)
        #expect(!observation.preserves())
    }
}

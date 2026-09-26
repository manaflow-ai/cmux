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
}

import Testing
@testable import CmuxWorkspaces

@Suite struct RestoredProcessDetectionObservationTests {
    @Test func armedLifecycleStatePreservesUntilCleared() {
        let armedAt = ContinuousClock.now
        var observation = RestoredProcessDetectionObservation()
        #expect(!observation.preserves(at: armedAt))
        observation.arm(at: armedAt)
        #expect(observation.preserves(at: armedAt))
        observation.clear()
        #expect(!observation.preserves(at: armedAt))
    }

    @Test func observationExpiresWithoutEvidence() {
        // A restored binding whose command never launches, or whose shell never
        // reports a prompt transition, must not be protected from empty scans
        // forever; after the window it retires like any unobserved binding.
        let armedAt = ContinuousClock.now
        var observation = RestoredProcessDetectionObservation()
        observation.arm(at: armedAt)
        let window = RestoredProcessDetectionObservation.observationWindow
        #expect(observation.preserves(at: armedAt.advanced(by: window - .seconds(1))))
        #expect(!observation.preserves(at: armedAt.advanced(by: window)))
    }
}

import Testing
@testable import CmuxWorkspaces

@Suite struct RestoredProcessDetectionObservationTests {
    @Test func boundedWindowDoesNotExtendAndClears() {
        var observation = RestoredProcessDetectionObservation(interval: 24)
        observation.arm(nowUptime: 100)
        #expect(observation.preserves(nowUptime: 123))
        #expect(!observation.preserves(nowUptime: 124))
        observation.clear()
        #expect(!observation.preserves(nowUptime: 100))
    }
}

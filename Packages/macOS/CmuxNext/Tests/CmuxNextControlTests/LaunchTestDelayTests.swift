import CmuxNextControl
import Testing

/// The launch bench's positive control knob: off unless set, a whole number of ms, never more than 5 s.
@Suite struct LaunchTestDelayTests {
    @Test func offUnlessSetToAPositiveWholeNumber() {
        #expect(LaunchTestDelay(environment: [:]) == nil)
        for text in ["", "0", "-5", "abc", "1.5", "500ms"] {
            #expect(LaunchTestDelay(environment: [LaunchTestDelay.variable: text]) == nil, "\(text)")
        }
    }

    @Test func readsTheDelay() {
        let delay = LaunchTestDelay(environment: [LaunchTestDelay.variable: "500"])
        #expect(delay?.milliseconds == 500)
        #expect(delay?.duration == .milliseconds(500))
        #expect(LaunchTestDelay(environment: [LaunchTestDelay.variable: " 250 "])?.milliseconds == 250)
    }

    @Test func clampedToTheLimit() {
        #expect(LaunchTestDelay.limit == 5000)
        #expect(LaunchTestDelay(environment: [LaunchTestDelay.variable: "5000"])?.milliseconds == 5000)
        #expect(LaunchTestDelay(environment: [LaunchTestDelay.variable: "600000"])?.milliseconds == 5000)
    }

    @MainActor @Test func atLaunchWaitsBetweenItsMarksOnlyWhenAsked() async throws {
        var marks: [String] = []
        try await LaunchTestDelay.atLaunch(environment: [:]) { marks.append($0) }
        #expect(marks.isEmpty)
        try await LaunchTestDelay.atLaunch(environment: [LaunchTestDelay.variable: "1"]) { marks.append($0) }
        #expect(marks == ["launch_test_delay_start", "launch_test_delay_end"])
    }
}

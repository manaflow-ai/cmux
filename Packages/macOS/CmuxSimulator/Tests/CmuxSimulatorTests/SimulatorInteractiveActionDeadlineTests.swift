import Testing

@testable import CmuxSimulator

@Suite("Simulator interactive action deadlines")
struct SimulatorInteractiveActionDeadlineTests {
    @Test("Long admitted key sequences receive their declared execution budget")
    func longKeySequenceTimeoutExceedsLegacyDeadline() {
        let action = SimulatorInteractiveAction.keyPresses(
            usages: Array(repeating: 0x04, count: 8),
            pressDurationMilliseconds: 50,
            interKeyDelayMilliseconds: 5_000
        )

        #expect(action.responseTimeout > .seconds(40))
    }
}

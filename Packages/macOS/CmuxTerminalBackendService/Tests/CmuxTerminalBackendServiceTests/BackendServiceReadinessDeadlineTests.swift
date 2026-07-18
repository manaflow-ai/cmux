@testable import CmuxTerminalBackendService
import Testing

@Suite("Persistent backend readiness deadline arbitration")
struct BackendServiceReadinessDeadlineTests {
    @Test("completion cannot cross the absolute deadline while awaiting the actor")
    func expiredCompletionLoses() async {
        let clock = ContinuousClock()
        let deadline = BackendServiceReadinessDeadline()
        let past = clock.now.advanced(by: .milliseconds(-1))

        #expect(!(await deadline.complete(clock: clock, before: past)))
        #expect(await deadline.expire())
    }
}

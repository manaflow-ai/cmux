@testable import CmuxTerminalBackendService
import Testing

@Suite("Persistent backend readiness retry policy")
struct BackendServiceReadinessRetryPolicyTests {
    @Test("launchd backoff doubles and stays at its bound")
    func boundedExponentialSchedule() {
        let policy = BackendServiceReadinessRetryPolicy.launchdStartup
        var delay = policy.initialDelay

        #expect(delay == .milliseconds(25))
        delay = policy.nextDelay(after: delay)
        #expect(delay == .milliseconds(50))
        delay = policy.nextDelay(after: delay)
        #expect(delay == .milliseconds(100))
        delay = policy.nextDelay(after: delay)
        #expect(delay == .milliseconds(200))
        delay = policy.nextDelay(after: delay)
        #expect(delay == .milliseconds(250))
        #expect(policy.nextDelay(after: delay) == .milliseconds(250))
    }
}

import Testing
@testable import CmuxComputerUse

struct ComputerUseHelperRetryPolicyTests {
    @Test func persistentFailureHasACappedExponentialRetryDeadline() {
        var policy = ComputerUseHelperRetryPolicy()
        var now = 100.0
        for delay in [5.0, 10, 20, 40, 80, 160, 300, 300] {
            #expect(policy.allowsAttempt(at: now))
            policy.recordFailure(at: now)
            #expect(!policy.allowsAttempt(at: now + delay - 0.1))
            now += delay
            #expect(policy.allowsAttempt(at: now))
        }
        policy.recordFailure(at: now)
        policy.reset()
        #expect(policy.allowsAttempt(at: now))
        policy.recordFailure(at: now)
        #expect(policy.allowsAttempt(at: now + 5))
    }
}

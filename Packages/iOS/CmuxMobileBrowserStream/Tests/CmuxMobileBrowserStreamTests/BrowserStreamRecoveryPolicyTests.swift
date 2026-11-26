import Testing
@testable import CmuxMobileBrowserStream

struct BrowserStreamRecoveryPolicyTests {
    @Test func idleSilenceNeverRestarts() {
        let policy = BrowserStreamRecoveryPolicy()
        #expect(!policy.shouldRestart(at: 1000))
    }

    @Test func answeredInputDoesNotRestart() {
        var policy = BrowserStreamRecoveryPolicy()
        policy.noteInput(at: 10)
        policy.noteFrame(at: 10.5)
        #expect(!policy.shouldRestart(at: 20))
    }

    @Test func unansweredInputRestartsAfterThreshold() {
        var policy = BrowserStreamRecoveryPolicy()
        policy.noteInput(at: 10)
        #expect(!policy.shouldRestart(at: 11))
        #expect(policy.shouldRestart(at: 12.6))
    }

    @Test func staleFrameBeforeInputStillRestarts() {
        var policy = BrowserStreamRecoveryPolicy()
        policy.noteFrame(at: 5)
        policy.noteInput(at: 10)
        #expect(policy.shouldRestart(at: 13))
    }

    @Test func restartBackoffSuppressesRepeats() {
        var policy = BrowserStreamRecoveryPolicy()
        policy.noteInput(at: 10)
        #expect(policy.shouldRestart(at: 13))
        policy.noteRestart(at: 13)
        #expect(!policy.shouldRestart(at: 15))
        #expect(policy.shouldRestart(at: 17.1))
    }

    @Test func resetClearsEvidence() {
        var policy = BrowserStreamRecoveryPolicy()
        policy.noteInput(at: 10)
        policy.reset()
        #expect(!policy.shouldRestart(at: 100))
    }
}

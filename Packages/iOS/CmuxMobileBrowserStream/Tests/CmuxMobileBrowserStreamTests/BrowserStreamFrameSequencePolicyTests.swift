import Testing
@testable import CmuxMobileBrowserStream

@Suite struct BrowserStreamFrameSequencePolicyTests {
    @Test func dropsOlderAndDuplicateDecodedFrames() {
        var policy = BrowserStreamFrameSequencePolicy()
        let acceptedEight = policy.accept(8)
        let acceptedSeven = policy.accept(7)
        let acceptedDuplicate = policy.accept(8)
        let acceptedTen = policy.accept(10)
        #expect(acceptedEight)
        #expect(!acceptedSeven)
        #expect(!acceptedDuplicate)
        #expect(acceptedTen)
        #expect(policy.newestDecodedSequence == 10)
    }

    @Test func resetAllowsSubscriptionSequenceRestart() {
        var policy = BrowserStreamFrameSequencePolicy()
        let acceptedOldSubscription = policy.accept(42)
        #expect(acceptedOldSubscription)
        policy.reset()
        let acceptedNewSubscription = policy.accept(1)
        #expect(acceptedNewSubscription)
    }
}

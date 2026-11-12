import Testing
@testable import CmuxCloudMachines

struct CloudGuestURLSubscriptionStateTests {
    @Test func metadataCannotRestartAnActiveOrUnsupportedStream() {
        var state = CloudGuestURLSubscriptionState()
        let active = state.recoverOnLinkProgress()
        #expect(!active)
        state.ended(exitCode: 1)
        for _ in 0..<100 {
            let rejected = state.recoverOnLinkProgress()
            #expect(!rejected)
        }
        state.ended(exitCode: 2)
        let unsupported = state.recoverOnLinkProgress()
        #expect(!unsupported)
    }

    @Test func recoversTransportLossWithinABoundedConnectionScope() {
        var state = CloudGuestURLSubscriptionState()
        for _ in 0..<2 {
            state.ended(exitCode: 3)
            let resumed = state.recoverOnLinkProgress()
            let duplicate = state.recoverOnLinkProgress()
            #expect(resumed)
            #expect(!duplicate)
        }
        state.ended(exitCode: 3)
        let exhausted = state.recoverOnLinkProgress()
        #expect(!exhausted)
        state = CloudGuestURLSubscriptionState()
        state.ended(exitCode: 3)
        let reconnected = state.recoverOnLinkProgress()
        #expect(reconnected)
    }
}

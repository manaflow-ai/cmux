import Testing
@testable import CmuxCloudMachines

struct CloudGuestURLSubscriptionStateTests {
    @Test func metadataCannotRestartAnActiveOrUnsupportedStream() {
        var state = CloudGuestURLSubscriptionState()
        #expect(!state.recoverOnLinkProgress())
        state.ended(exitCode: 1)
        for _ in 0..<100 { #expect(!state.recoverOnLinkProgress()) }
        state.ended(exitCode: 2)
        #expect(!state.recoverOnLinkProgress())
    }

    @Test func recoversTransportLossWithinABoundedConnectionScope() {
        var state = CloudGuestURLSubscriptionState()
        for _ in 0..<2 {
            state.ended(exitCode: 3)
            #expect(state.recoverOnLinkProgress())
            #expect(!state.recoverOnLinkProgress())
        }
        state.ended(exitCode: 3)
        #expect(!state.recoverOnLinkProgress())
        state = CloudGuestURLSubscriptionState()
        state.ended(exitCode: 3)
        #expect(state.recoverOnLinkProgress())
    }
}

import Testing
@testable import CmuxMobileLive

/// A refused `auth` on a live link is asked again by the phone itself (2026-11-03: the Mac's
/// "Allow iPhone to connect?" came only after a relaunch of the Mac app, 10 minutes after the
/// phone opened, because a refusal stood until someone tapped Retry).
@Suite struct PairingRetryTests {
    @Test func aMacThatWasNotReadyIsAskedAgainSoonThenEvery30SecondsThenWaitsForRetry() {
        for code in ["unavailable", "timeout", "closed", "pairing", "busy"] {
            let delays = (0..<12).map { LinkPairing.retryDelay(after: code, attempt: $0) }
            // Before: every 30 s for as long as the link lived. Now about 2.5 min of tries, then
            // the refusal stays up with Retry (a new link starts over).
            #expect(delays == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30), .seconds(30), .seconds(30),
                               nil, nil, nil, nil])
        }
    }

    @Test func aPhoneTheMacRefusedWaitsForThePerson() {
        #expect(LinkPairing.retryDelay(after: "denied", attempt: 0) == nil)
    }

    /// A host that proved another identity (or answered for another Mac) is not asked again on the
    /// same link: the warning stays up, and a new link pairs from the start.
    @Test func aHostThatCannotProveThisMacIsNotAskedAgainOnTheSameLink() {
        for code in ["mac_identity_changed", "bad_mac_proof", "wrong_mac", "bad_request", "unpaired"] {
            #expect(LinkPairing.retryDelay(after: code, attempt: 0) == nil)
        }
    }

    @Test func aRateLimitedAskWaitsAMinuteAFewTimes() {
        #expect(LinkPairing.retryDelay(after: "rate_limited", attempt: 0) == .seconds(60))
        #expect(LinkPairing.retryDelay(after: "rate_limited", attempt: 2) == .seconds(60))
        #expect(LinkPairing.retryDelay(after: "rate_limited", attempt: 3) == nil)
    }

    /// Every automatic retry has a last try (no-hangs): the team load and the chats' bind.
    @Test func teamStartAndChatsRebindStop() {
        let team = (1...7).map { RetryBounds.teamStartDelay(afterFailures: $0) }
        #expect(team == [.seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(60), nil, nil])
        let chats = (0..<7).map { RetryBounds.chatsRebindDelay(attempt: $0) }
        #expect(chats == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), nil, nil])
    }
}

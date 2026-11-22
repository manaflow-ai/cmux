import Testing
@testable import CmuxMobileLive

/// A refused `auth` on a live link is asked again by the phone itself (2026-11-03: the Mac's
/// "Allow iPhone to connect?" came only after a relaunch of the Mac app, 10 minutes after the
/// phone opened, because a refusal stood until someone tapped Retry).
@Suite struct PairingRetryTests {
    @Test func aMacThatWasNotReadyIsAskedAgainSoonThenEvery30Seconds() {
        for code in ["unavailable", "timeout", "closed", "pairing", "busy"] {
            let delays = (0..<8).map { LinkPairing.retryDelay(after: code, attempt: $0) }
            #expect(delays == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30), .seconds(30), .seconds(30)])
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

    @Test func aRateLimitedAskWaitsAMinute() {
        #expect(LinkPairing.retryDelay(after: "rate_limited", attempt: 0) == .seconds(60))
    }
}

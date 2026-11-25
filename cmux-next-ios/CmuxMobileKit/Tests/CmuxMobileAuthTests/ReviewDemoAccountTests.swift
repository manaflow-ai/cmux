#if os(iOS)
@testable import CmuxMobileAuth
import Testing

/// Only the App Review demo account gets the simulated Mac: its exact address, or Stack's
/// server-written `cmuxReviewDemoContent` flag. Every other account keeps live data.
@Suite struct ReviewDemoAccountTests {
    @Test func theReviewAccountGetsTheDemo() {
        #expect(CmuxMobileAuthModel.isReviewDemoAccount(email: "cmux-rev-0e6ba145@mailinator.com", serverFlag: false))
        #expect(CmuxMobileAuthModel.isReviewDemoAccount(email: " CMUX-Rev-0e6ba145@Mailinator.com ", serverFlag: false))
    }

    @Test func otherAccountsDoNot() {
        for email in ["aziz@manaflow.ai", "cmux-rev-0e6ba145@mailinator.co", "x-cmux-rev-0e6ba145@mailinator.com",
                      "cmux-review@mailinator.com", ""] {
            #expect(!CmuxMobileAuthModel.isReviewDemoAccount(email: email, serverFlag: false), "\(email)")
        }
        #expect(!CmuxMobileAuthModel.isReviewDemoAccount(email: nil, serverFlag: false))
    }

    @Test func theServerFlagTurnsItOnForAnyAccount() {
        #expect(CmuxMobileAuthModel.isReviewDemoAccount(email: "someone@example.com", serverFlag: true))
        #expect(CmuxMobileAuthModel.isReviewDemoAccount(email: nil, serverFlag: true))
    }
}
#endif

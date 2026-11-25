#if os(iOS)
import CmuxMobileShellModel
@testable import CmuxMobileShellUI
import Testing

@Suite struct OnboardingDemonstrationAccountPolicyTests {
    /// App Review (iPad, 2026-11-07) signed in with the demonstration account,
    /// whose Demo Mac never counts as a live connection, and was held on
    /// "Couldn't connect to your Mac yet". The demonstration account's Demo
    /// Mac is its Mac: the connect step is ready.
    @Test func demonstrationAccountIsReadyWithoutALiveMac() {
        let policy = OnboardingDemonstrationAccountPolicy(isDemonstrationAccount: true)
        for phase in [OnboardingConnectionPhase.idle, .searching, .fallback, .ready] {
            #expect(policy.connectionPhase(phase) == .ready, "live phase \(phase)")
        }
    }

    /// The reviewer has no Tailscale network; never offer Tailscale Only.
    @Test func demonstrationAccountHidesTheConnectionMethodChoice() {
        let policy = OnboardingDemonstrationAccountPolicy(isDemonstrationAccount: true)
        #expect(!policy.offersConnectionMethodChoice)
        #expect(policy.connectionMethod(.tailscale) == .automatic)
        #expect(policy.connectionMethod(.automatic) == .automatic)
    }

    @Test func everyOtherAccountKeepsTheLiveFlow() {
        let policy = OnboardingDemonstrationAccountPolicy(isDemonstrationAccount: false)
        for phase in [OnboardingConnectionPhase.idle, .searching, .fallback, .ready] {
            #expect(policy.connectionPhase(phase) == phase)
        }
        #expect(policy.offersConnectionMethodChoice)
        #expect(policy.connectionMethod(.tailscale) == .tailscale)
        #expect(policy.connectionMethod(.automatic) == .automatic)
    }
}
#endif

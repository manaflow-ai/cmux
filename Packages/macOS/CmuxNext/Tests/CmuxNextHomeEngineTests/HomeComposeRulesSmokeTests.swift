import CmuxHomeCore
import CmuxNextHomeEngine
@testable import CmuxNextHomeModel
import Testing

/// The send path through the Rust compose rules (`compose.*` over
/// cmux_home_call): one round trip each way through the Swift types. The cases themselves are the
/// Rust tests (cmux-tui/crates/cmux-home-rules/tests/compose_*.rs).
@MainActor @Suite struct HomeComposeRulesSmokeTests {
    @Test func outcomesAndQuotesRoundTrip() {
        #expect(HomeGroupOutcome(rejection: .invalid("not_reachable"), naming: "Ada") == .notReachable("Ada"))
        #expect(HomeTeamSeatImpact.of(canInvite: true, planID: "team", hasSubscription: true, memberCount: 3, memberLimit: nil)
            == .paidSeat(members: 3))
        #expect(HomeMessageRouting.quoted("a\n\nb") == "> a\n>\n> b\n\n")
    }
}

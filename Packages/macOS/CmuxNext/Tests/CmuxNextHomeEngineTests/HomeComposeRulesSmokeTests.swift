import CmuxHomeCore
@testable import CmuxNextHome
@testable import CmuxNextHomeModel
import Testing

/// New Message and the send path through the Rust compose rules (`compose.*` over
/// cmux_home_call): one round trip each way through the Swift types. The cases themselves are the
/// Rust tests (cmux-tui/crates/cmux-home-rules/tests/compose_*.rs).
@Suite struct HomeComposeRulesSmokeTests {
    @Test func aDraftAndAGroupOutcomeRoundTrip() {
        let ada = HomeContact(id: ParticipantID("ada"), name: "Ada Lovelace", source: .team)
        var draft = HomeNewMessageDraft()
        draft.query = "Ada"
        #expect(draft.commit(contacts: [ada]))
        #expect(draft.recipients == [.contact(ada)])
        #expect(draft.query.isEmpty)
        #expect(HomeGroupOutcome(rejection: .invalid("not_reachable"), naming: "Ada") == .notReachable("Ada"))
        #expect(HomeTeamSeatImpact.of(canInvite: true, planID: "team", hasSubscription: true, memberCount: 3, memberLimit: nil)
            == .paidSeat(members: 3))
    }
}

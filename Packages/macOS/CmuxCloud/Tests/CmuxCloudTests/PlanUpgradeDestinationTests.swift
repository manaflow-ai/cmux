import CmuxCloud
import Foundation
import Testing

/// A locked size or a full pool names the plan that unlocks it. Team Max is a
/// team subscription, so it must never open the personal Max checkout.
@Suite("Plan upgrade destination")
struct PlanUpgradeDestinationTests {
    @Test("personal plans open their checkout")
    func personalPlansOpenCheckout() {
        #expect(PlanUpgradeDestination(planID: "pro", teamID: "team-1") == .checkout(.pro))
        #expect(PlanUpgradeDestination(planID: "go", teamID: nil) == .checkout(.go))
        #expect(PlanUpgradeDestination(planID: " MAX ", teamID: "team-1") == .checkout(.max))
        // Older servers omit the plan; Max has always sold the locked sizes.
        #expect(PlanUpgradeDestination(planID: nil, teamID: nil) == .checkout(.max))
    }

    @Test("Team Max opens the selected team's billing")
    func teamMaxOpensTeamBilling() {
        #expect(PlanUpgradeDestination(planID: "team_max", teamID: "team-1") == .teamBilling(teamID: "team-1"))
        #expect(PlanUpgradeDestination(planID: " Team_Max ", teamID: " team-1 ") == .teamBilling(teamID: "team-1"))
    }

    @Test("Team Max without a known team opens pricing, never personal Max")
    func teamMaxWithoutTeamOpensPricing() {
        #expect(PlanUpgradeDestination(planID: "team_max", teamID: nil) == .pricing)
        #expect(PlanUpgradeDestination(planID: "team_max", teamID: "  ") == .pricing)
    }

    @Test("team billing URL selects the team on the billing dashboard")
    func teamBillingURL() throws {
        let origin = try #require(URL(string: "https://cmux.com"))
        let url = PlanUpgradeDestination.teamBillingURL(teamID: "11111111-1111-4111-8111-111111111111", origin: origin)
        #expect(url.absoluteString == "https://cmux.com/dashboard/billing?team=11111111-1111-4111-8111-111111111111")
    }
}

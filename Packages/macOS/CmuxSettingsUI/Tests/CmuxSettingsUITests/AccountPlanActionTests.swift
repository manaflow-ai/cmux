import Foundation
import Observation
import Testing

@testable import CmuxSettingsUI

@MainActor
struct AccountPlanActionTests {
    @Test func grantedProCanOpenMaxPricing() {
        let flow = PlanActionFlow()
        flow.isProActive = true
        flow.isPersonalProActive = true

        #expect(flow.planAction == .upgradeToMax)
        invoke(flow.planAction, using: flow)

        #expect(flow.pricingOpenCount == 1)
        #expect(flow.billingPortalOpenCount == 0)
    }

    @Test func grantedMaxHasNoUpgradeAction() {
        let flow = PlanActionFlow()
        flow.isProActive = true
        flow.isMaxActive = true

        #expect(flow.planAction == nil)
        invoke(flow.planAction, using: flow)

        #expect(flow.pricingOpenCount == 0)
        #expect(flow.billingPortalOpenCount == 0)
    }

    @Test(arguments: [false, true])
    func manageableProAndMaxKeepTheBillingPortal(isMax: Bool) {
        let flow = PlanActionFlow()
        flow.isProActive = true
        flow.isPersonalProActive = !isMax
        flow.isMaxActive = isMax
        flow.canManageBilling = true

        #expect(flow.planAction == .manageBilling)
        invoke(flow.planAction, using: flow)

        #expect(flow.billingPortalOpenCount == 1)
        #expect(flow.pricingOpenCount == 0)
    }

    @Test(arguments: [false, true])
    func otherPersonalPlansOfferProRegardlessOfTeamAccess(hasCloudAccess: Bool) {
        let flow = PlanActionFlow()
        flow.isProActive = hasCloudAccess

        #expect(flow.planAction == .upgradeToPro)
        invoke(flow.planAction, using: flow)

        #expect(flow.pricingOpenCount == 1)
        #expect(flow.billingPortalOpenCount == 0)
    }

    private func invoke(_ action: AccountPlanAction?, using flow: PlanActionFlow) {
        switch action {
        case .manageBilling:
            flow.openBillingPortal()
        case .upgradeToPro, .upgradeToMax:
            flow.openProUpgrade()
        case nil:
            break
        }
    }
}

@MainActor
@Observable
private final class PlanActionFlow: AccountFlow {
    var currentIdentity: AccountIdentity? { nil }
    var availableTeams: [AccountTeamSummary] { [] }
    var selectedTeamID: String? { nil }
    var isWorkingOnAuth: Bool { false }
    var signInIsSlow: Bool { false }
    var isProActive = false
    var isPersonalProActive = false
    var isMaxActive = false
    var canManageBilling = false
    var pricingOpenCount = 0
    var billingPortalOpenCount = 0

    func selectTeam(id: String?) async throws {}
    func startSignIn() {}
    func openSignInInDefaultBrowser() {}
    func signOut() async {}
    func refreshCurrentUser() async {}
    func refreshBillingPlan() async {}
    func openProUpgrade() { pricingOpenCount += 1 }
    func openBillingPortal() { billingPortalOpenCount += 1 }
}

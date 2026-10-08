import Foundation
import Observation
import Testing
@testable import CmuxSettingsUI

@MainActor
@Suite("Pro upgrade card")
struct ProUpgradeCardTests {
    @Test("a restored Pro account loads without activating Cloud")
    func restoredAccountLoadsPlan() async {
        let flow = PlanTestAccountFlow()
        let model = AccountPlanModel()
        let restoring = AccountPlanRefreshKey(flow: flow)

        #expect(model.presentation(flow: flow, key: restoring) == .checking)
        await model.refresh(flow: flow, key: restoring)
        #expect(flow.refreshCount == 0)

        // The identity is already cached on the other Mac. Only auth readiness
        // changes; no Cloud activation or machines client participates.
        flow.isWorkingOnAuth = false
        flow.isAuthenticated = true
        let ready = AccountPlanRefreshKey(flow: flow)
        #expect(ready != restoring)
        await model.refresh(flow: flow, key: ready)

        #expect(flow.refreshCount == 1)
        #expect(model.presentation(flow: flow, key: ready) == .managedPro)
    }

    @Test("team confirmation refreshes the plan after an optimistic picker change")
    func confirmedTeamRefreshesPlan() async {
        let flow = PlanTestAccountFlow()
        flow.isWorkingOnAuth = false
        flow.isAuthenticated = true
        flow.result = (isPro: false, canManage: false)
        let model = AccountPlanModel()
        var lastKey: AccountPlanRefreshKey?

        // Model the keyed task's lifecycle: the view restarts a lookup only
        // when its observed key changes. Requests use confirmed authority.
        func updateCard() async {
            let key = AccountPlanRefreshKey(flow: flow)
            guard key != lastKey else { return }
            lastKey = key
            await model.refresh(flow: flow, key: key)
        }

        await updateCard()
        flow.selectedTeamID = "paid-team"
        await updateCard()
        #expect(flow.refreshCount == 1)

        flow.confirmedTeamID = "paid-team"
        flow.result = (isPro: true, canManage: false)
        await updateCard()
        #expect(flow.refreshedTeams == [nil, "paid-team"])
        #expect(model.presentation(flow: flow, key: AccountPlanRefreshKey(flow: flow)) == .pro)

        // A rejected optimistic switch must not replace the paid team's plan.
        flow.selectedTeamID = "rejected-team"
        await updateCard()
        flow.selectedTeamID = "paid-team"
        await updateCard()
        #expect(flow.refreshCount == 2)
        #expect(model.presentation(flow: flow, key: AccountPlanRefreshKey(flow: flow)) == .pro)
    }

    @Test("a failed lookup offers retry instead of an upgrade")
    func failedLookupCanRetry() async {
        let flow = PlanTestAccountFlow()
        flow.isWorkingOnAuth = false
        flow.isAuthenticated = true
        flow.result = nil
        let model = AccountPlanModel()
        let first = AccountPlanRefreshKey(flow: flow)
        await model.refresh(flow: flow, key: first)
        #expect(model.presentation(flow: flow, key: first) == .unavailable)

        flow.result = (isPro: true, canManage: true)
        let retry = AccountPlanRefreshKey(flow: flow, generation: 1)
        #expect(model.presentation(flow: flow, key: retry) == .checking)
        await model.refresh(flow: flow, key: retry)
        #expect(flow.refreshCount == 2)
        #expect(model.presentation(flow: flow, key: retry) == .managedPro)
    }

    @Test("verified plans choose the corresponding account action", arguments: [false, true])
    func verifiedPlans(isPro: Bool) async {
        let flow = PlanTestAccountFlow()
        flow.isWorkingOnAuth = false
        flow.isAuthenticated = true
        flow.result = (isPro: isPro, canManage: false)
        let model = AccountPlanModel()
        let key = AccountPlanRefreshKey(flow: flow)
        await model.refresh(flow: flow, key: key)
        #expect(model.presentation(flow: flow, key: key) == (isPro ? .pro : .free))
    }

    @Test("restoring auth hides upgrade even before an identity is available")
    func restorationWithoutIdentity() async {
        let flow = PlanTestAccountFlow()
        flow.currentIdentity = nil
        flow.isProStatusKnown = true
        let model = AccountPlanModel()
        let restoring = AccountPlanRefreshKey(flow: flow)
        #expect(model.presentation(flow: flow, key: restoring) == .checking)
        await model.refresh(flow: flow, key: restoring)
        #expect(flow.refreshCount == 0)

        flow.isWorkingOnAuth = false
        let signedOut = AccountPlanRefreshKey(flow: flow)
        #expect(model.presentation(flow: flow, key: signedOut) == .free)
        await model.refresh(flow: flow, key: signedOut)
        #expect(flow.refreshCount == 0)
    }

    @Test("a team switch clears the previous lookup's error presentation")
    func errorBelongsToRequestedScope() async {
        let flow = PlanTestAccountFlow()
        flow.isWorkingOnAuth = false
        flow.isAuthenticated = true
        flow.result = nil
        let model = AccountPlanModel()
        let personal = AccountPlanRefreshKey(flow: flow)
        await model.refresh(flow: flow, key: personal)
        #expect(model.presentation(flow: flow, key: personal) == .unavailable)

        flow.selectedTeamID = "team-2"
        flow.confirmedTeamID = "team-2"
        let team = AccountPlanRefreshKey(flow: flow)
        #expect(model.presentation(flow: flow, key: team) == .checking)
        flow.result = (isPro: true, canManage: false)
        await model.refresh(flow: flow, key: team)
        #expect(model.presentation(flow: flow, key: team) == .pro)
    }
}

@MainActor
@Observable
private final class PlanTestAccountFlow: AccountFlow {
    var currentIdentity: AccountIdentity? = AccountIdentity(
        id: "account-1", displayName: "Test", email: "test@example.com"
    )
    var availableTeams: [AccountTeamSummary] = []
    var selectedTeamID: String?
    var confirmedTeamID: String?
    var refreshedTeams: [String?] = []
    var isWorkingOnAuth = true
    var isAuthenticated = false
    var signInIsSlow = false
    var isProUpgradeAvailable = true
    var isProStatusKnown = false
    var isProActive = false
    var canManageBilling = false
    var refreshCount = 0
    var result: (isPro: Bool, canManage: Bool)? = (true, true)

    func refreshBillingPlan() async {
        refreshCount += 1
        refreshedTeams.append(confirmedTeamID)
        if let result {
            isProActive = result.isPro
            canManageBilling = result.canManage
            isProStatusKnown = true
        }
    }

    func selectTeam(id: String?) async throws { selectedTeamID = id }
    func startSignIn() {}
    func openSignInInDefaultBrowser() {}
    func signOut() async {}
    func refreshCurrentUser() async {}
    func openProUpgrade() {}
    func openBillingPortal() {}
}

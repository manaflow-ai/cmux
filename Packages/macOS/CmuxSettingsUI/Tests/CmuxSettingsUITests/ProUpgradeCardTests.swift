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
        flow.isWorkingOnAuth = false
        flow.isAuthenticated = true
        flow.result = (isPro: true, canManage: true)

        #expect(flow.accountPlanStatus == .checking)
        await flow.refreshBillingPlan()

        // The plan request is independent of Cloud activation and the host
        // exposes the resolved managed-Pro snapshot to Settings.
        #expect(flow.refreshCount == 1)
        #expect(flow.accountPlanStatus == .managedPro)
    }

    @Test("auth restoration keeps the plan row in checking")
    func restorationWithoutIdentity() {
        let flow = PlanTestAccountFlow()
        flow.currentIdentity = nil
        flow.isWorkingOnAuth = true
        #expect(flow.accountPlanStatus == .checking)

        flow.isWorkingOnAuth = false
        #expect(flow.accountPlanStatus == .free)
    }

    @Test("a free account exposes the upgrade action after its plan is known")
    func freePlanShowsUpgrade() async {
        let flow = PlanTestAccountFlow()
        flow.isWorkingOnAuth = false
        flow.isAuthenticated = true
        flow.result = (isPro: false, canManage: false)

        await flow.refreshBillingPlan()

        #expect(flow.accountPlanStatus == .free)
    }

    @Test("a failed lookup exposes retry through the host snapshot")
    func failedLookupCanRetry() async {
        let flow = PlanTestAccountFlow()
        flow.isWorkingOnAuth = false
        flow.isAuthenticated = true
        flow.result = nil

        await flow.refreshBillingPlan()
        #expect(flow.accountPlanStatus == .unavailable)

        flow.result = (isPro: true, canManage: true)
        await flow.retryBillingPlan()
        #expect(flow.refreshCount == 2)
        #expect(flow.accountPlanStatus == .managedPro)
    }

    @Test("refreshes keep a verified plan visible")
    func refreshKeepsKnownPlanVisible() {
        let flow = PlanTestAccountFlow()
        flow.isWorkingOnAuth = false
        flow.isProStatusKnown = true
        flow.isProActive = true
        flow.canManageBilling = true

        flow.isRefreshing = true
        #expect(flow.accountPlanStatus == .managedPro)

        flow.isRefreshing = false
        flow.lookupFailed = true
        #expect(flow.accountPlanStatus == .managedPro)
    }

    @Test("team scope is part of the plan snapshot")
    func teamScopeChangesPlan() async {
        let flow = PlanTestAccountFlow()
        flow.isWorkingOnAuth = false
        flow.isAuthenticated = true
        flow.confirmedTeamID = "team-a"
        flow.selectedTeamID = "team-a"
        flow.result = (isPro: true, canManage: false)

        await flow.refreshBillingPlan()
        #expect(flow.refreshedTeams == ["team-a"])
        #expect(flow.accountPlanStatus == .pro)

        flow.confirmedTeamID = "team-b"
        flow.selectedTeamID = "team-b"
        flow.isProStatusKnown = false
        flow.statusOverride = .checking
        #expect(flow.accountPlanStatus == .checking)
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
    var statusOverride: AccountPlanStatus?
    var isRefreshing = false
    var lookupFailed = false

    var accountPlanStatus: AccountPlanStatus {
        if let statusOverride { return statusOverride }
        if isWorkingOnAuth { return .checking }
        guard currentIdentity != nil else { return .free }
        if isProStatusKnown {
            if isProActive { return canManageBilling ? .managedPro : .pro }
            return .free
        }
        if lookupFailed { return .unavailable }
        if isRefreshing { return .checking }
        return .checking
    }

    func refreshBillingPlan() async {
        refreshCount += 1
        refreshedTeams.append(confirmedTeamID)
        statusOverride = nil
        isRefreshing = true
        if let result {
            isProActive = result.isPro
            canManageBilling = result.canManage
            isProStatusKnown = true
            lookupFailed = false
        } else {
            isProStatusKnown = false
            lookupFailed = true
        }
        isRefreshing = false
    }

    func selectTeam(id: String?) async throws { selectedTeamID = id }
    func startSignIn() {}
    func openSignInInDefaultBrowser() {}
    func signOut() async {}
    func refreshCurrentUser() async {}
    func openProUpgrade() {}
    func openBillingPortal() {}
}

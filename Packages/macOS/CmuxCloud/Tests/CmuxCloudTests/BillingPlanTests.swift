@testable import CmuxCloud
import Foundation
import Testing

@Suite("Billing plan state")
struct BillingPlanTests {
    @Test("exact personal plan is independent of Cloud entitlement", arguments: ["free", "go", "pro", "max"])
    func exactPersonalPlan(plan: String) throws {
        let data = Data("""
        {"isPro":true,"planId":"pro","subscriptionPlanId":"\(plan)","teamPlanId":"team","teamBillingManagement":"stripe"}
        """.utf8)
        let details = try BillingPlanClient.decode(data)
        let state = BillingPlanState.unknown.applyingSuccess(
            for: "account-a", isPro: details.isPro, canManageBilling: details.canManageBilling, planID: details.planID
        )
        #expect(state.isPro)
        #expect(state.planID == plan)
        #expect(state.isPersonalPro == (plan == "pro"))
        #expect(state.isMax == (plan == "max"))
    }

    @Test("older billing responses still identify personal Pro")
    func legacyPlanResponse() throws {
        let details = try BillingPlanClient.decode(Data(#"{"planId":"pro","billingManagement":"stripe"}"#.utf8))
        #expect(details.planID == "pro")
        #expect(details.isPro)
        #expect(details.canManageBilling)
    }

    @Test("successful response is scoped to its account")
    func successScopesAccount() {
        let state = BillingPlanState.unknown.applyingSuccess(
            for: "account-a",
            isPro: true,
            canManageBilling: true,
            planID: "max"
        )
        #expect(state.accountID == "account-a")
        #expect(state.isPro)
        #expect(state.canManageBilling)
        #expect(state.isMax)
    }

    @Test("same-account failure preserves the last known answer")
    func sameAccountFailurePreservesAnswer() {
        let state = BillingPlanState(accountID: "account-a", isPro: true, canManageBilling: true, planID: "max")
        #expect(state.applyingFailure(for: "account-a") == state)
    }

    @Test("different-account failure clears the answer")
    func differentAccountFailureClearsAnswer() {
        let state = BillingPlanState(accountID: "account-a", isPro: true, canManageBilling: true, planID: "max")
        #expect(state.applyingFailure(for: "account-b") == .unknown)
    }
}

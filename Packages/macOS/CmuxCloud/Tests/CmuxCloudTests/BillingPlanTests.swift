import CmuxCloud
import Testing

@Suite("Billing plan state")
struct BillingPlanTests {
    @Test("successful response is scoped to its account")
    func successScopesAccount() {
        let state = BillingPlanState.unknown.applyingSuccess(
            for: "account-a",
            teamID: "team-a",
            isPro: true,
            canManageBilling: true
        )
        #expect(state.accountID == "account-a")
        #expect(state.teamID == "team-a")
        #expect(state.isPro)
        #expect(state.canManageBilling)
    }

    @Test("same-account failure preserves the last known answer")
    func sameAccountFailurePreservesAnswer() {
        let state = BillingPlanState(accountID: "account-a", teamID: "team-a", isPro: true, canManageBilling: true)
        #expect(state.applyingFailure(for: "account-a", teamID: "team-a") == state)
    }

    @Test("different-account failure clears the answer")
    func differentAccountFailureClearsAnswer() {
        let state = BillingPlanState(accountID: "account-a", teamID: "team-a", isPro: true, canManageBilling: true)
        #expect(state.applyingFailure(for: "account-b", teamID: "team-a") == .unknown)
    }

    @Test("different team failure clears the answer")
    func differentTeamFailureClearsAnswer() {
        let state = BillingPlanState(accountID: "account-a", teamID: "team-a", isPro: true, canManageBilling: true)
        #expect(state.applyingFailure(for: "account-a", teamID: "team-b") == .unknown)
    }
}

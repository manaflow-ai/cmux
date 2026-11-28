import CmuxCloud
import Testing

@Suite("Billing plan state")
struct BillingPlanTests {
    @Test("successful response is scoped to its account")
    func successScopesAccount() {
        let state = BillingPlanState.unknown.applyingSuccess(
            for: "account-a",
            isPro: true,
            canManageBilling: true,
            teamID: "team-a"
        )
        #expect(state.accountID == "account-a")
        #expect(state.teamID == "team-a")
        #expect(state.isPro)
        #expect(state.canManageBilling)
    }

    @Test("a plan snapshot does not remain loaded after the selected team changes")
    func successIsScopedToTeam() {
        let state = BillingPlanState.unknown.applyingSuccess(
            for: "account-a",
            isPro: true,
            canManageBilling: true,
            teamID: "team-a"
        )

        #expect(state.matches(accountID: "account-a", teamID: "team-a"))
        #expect(!state.matches(accountID: "account-a", teamID: "team-b"))
    }

    @Test("same-account failure preserves the last known answer")
    func sameAccountFailurePreservesAnswer() {
        let state = BillingPlanState(accountID: "account-a", isPro: true, canManageBilling: true, teamID: "team-a")
        #expect(state.applyingFailure(for: "account-a", teamID: "team-a") == state)
        #expect(state.applyingFailure(for: "account-a", teamID: "team-b") == .unknown)
        #expect(state.applyingFailure(for: "account-a", teamID: nil) == .unknown)
    }

    @Test("different-account failure clears the answer")
    func differentAccountFailureClearsAnswer() {
        let state = BillingPlanState(accountID: "account-a", isPro: true, canManageBilling: true, teamID: "team-a")
        #expect(state.applyingFailure(for: "account-b", teamID: "team-a") == .unknown)
    }
}

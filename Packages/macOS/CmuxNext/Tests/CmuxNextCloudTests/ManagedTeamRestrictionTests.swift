import Testing
@testable import CmuxNextCloud

/// `RestrictToManagedTeam` with `ManagedTeam` (enterprise P17-3).
@Suite struct ManagedTeamRestrictionTests {
    @Test func unrestrictedUsesTheResolvedTeam() {
        #expect(CloudAuth.allowedTeamID(resolved: "team_b", available: ["team_a", "team_b"], managed: nil) == "team_b")
    }

    @Test func restrictedUsesOnlyTheManagedTeam() {
        #expect(CloudAuth.allowedTeamID(resolved: "team_b", available: ["team_a", "team_b"], managed: "team_a") == "team_a")
    }

    /// An account outside the managed team gets no team at all, never another one.
    @Test func anAccountWithoutTheManagedTeamHasNone() {
        #expect(CloudAuth.allowedTeamID(resolved: "team_b", available: ["team_b"], managed: "team_a") == nil)
    }
}

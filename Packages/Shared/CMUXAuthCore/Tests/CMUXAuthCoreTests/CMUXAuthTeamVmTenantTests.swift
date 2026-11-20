import CMUXAuthCore
import Foundation
import Testing

/// CMUX-380: the private Stack team cmux makes for the VM API (a "Personal" team the person is the only member of)
/// was listed as one of the person's teams and became the active team, so `cmux auth token` was refused. The server
/// marks it in the team's read-only metadata; the sign-in client leaves a marked team out of the person's teams.
@Suite("CMUXAuthTeam VM personal tenant")
struct CMUXAuthTeamVmTenantTests {
    @Test("Only the server's mark makes a team a VM personal tenant")
    func onlyTheMarkCounts() {
        #expect(CMUXAuthTeam.isVmPersonalTenant(clientReadOnlyMetadata: ["cmuxVmPersonalTenant": true]))
        #expect(CMUXAuthTeam.isVmPersonalTenant(clientReadOnlyMetadata: ["cmuxPlan": "pro", "cmuxVmPersonalTenant": true]))
        #expect(!CMUXAuthTeam.isVmPersonalTenant(clientReadOnlyMetadata: [:]))
        #expect(!CMUXAuthTeam.isVmPersonalTenant(clientReadOnlyMetadata: ["cmuxPlan": "team"]))
        #expect(!CMUXAuthTeam.isVmPersonalTenant(clientReadOnlyMetadata: ["cmuxVmPersonalTenant": false]))
        #expect(!CMUXAuthTeam.isVmPersonalTenant(clientReadOnlyMetadata: ["cmuxVmPersonalTenant": "true"]))
    }
}

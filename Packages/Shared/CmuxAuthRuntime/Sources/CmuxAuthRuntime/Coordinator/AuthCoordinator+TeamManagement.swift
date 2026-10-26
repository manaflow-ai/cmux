public import CMUXAuthCore
import Foundation

public extension AuthCoordinator {
    /// The signed-in user's teams with roles. A client without team
    /// management answers the membership already loaded, roles unknown.
    func teamMemberships() async throws -> CMUXTeamMemberships {
        guard isAuthenticated else { throw CMUXTeamError.signedOut }
        guard let manager = client as? any TeamManaging else {
            return CMUXTeamMemberships(teams: availableTeams.map(CMUXTeamMembership.init(team:)), selectedTeamID: selectedTeamID)
        }
        return try await runPhase(.teamManagement, timeout: timeouts.network) {
            try await manager.teamMemberships()
        }
    }

    /// One team's detail (members, pending invitations, billing, the user's role).
    func teamDetail(id: String) async throws -> CMUXTeamDetail {
        guard isAuthenticated else { throw CMUXTeamError.signedOut }
        guard let manager = client as? any TeamManaging else { throw CMUXTeamError.unavailable }
        return try await runPhase(.teamManagement, timeout: timeouts.network) {
            try await manager.teamDetail(id: id)
        }
    }

    /// Renames a team (admins only), then shows the new name in the
    /// membership list at once and re-reads it.
    /// - Returns: The renamed team as the server stored it.
    @discardableResult
    func renameTeam(id: String, displayName: String) async throws -> CMUXAuthTeam {
        let name = try CMUXTeamName(displayName)
        guard isAuthenticated else { throw CMUXTeamError.signedOut }
        guard let manager = client as? any TeamManaging else { throw CMUXTeamError.unavailable }
        let generation = sessionGeneration
        let renamed = try await runPhase(.teamManagement, timeout: timeouts.network) {
            try await manager.renameTeam(id: id, displayName: name.value)
        }
        guard generation == sessionGeneration, isAuthenticated else { throw AuthError.unauthorized }
        if let index = availableTeams.firstIndex(where: { $0.id == id }) {
            availableTeams[index] = CMUXAuthTeam(id: id, displayName: renamed.displayName, slug: availableTeams[index].slug)
        }
        await refreshTeams()
        return renamed
    }

    /// Deletes a team (admins only). The team leaves the membership list at
    /// once; when it was the active team, the first remaining team becomes
    /// active and is saved as the account's selection, as after leaving a team.
    func deleteTeam(id: String) async throws {
        guard isAuthenticated else { throw CMUXTeamError.signedOut }
        guard let manager = client as? any TeamManaging else { throw CMUXTeamError.unavailable }
        guard !isSelectingTeam, !isCreatingTeam else { throw CMUXTeamError.busy }
        let generation = sessionGeneration
        let wasActive = resolvedTeamID == id
        try await runPhase(.teamManagement, timeout: timeouts.network) {
            try await manager.deleteTeam(id: id)
        }
        guard generation == sessionGeneration, isAuthenticated else { throw AuthError.unauthorized }
        // A refresh already in flight read the list with the team in it: this
        // change is newer than its answer.
        teamMutationGeneration &+= 1
        availableTeams.removeAll { $0.id == id }
        if wasActive { selectedTeamID = availableTeams.first?.id }
        await refreshTeams()
        guard wasActive, generation == sessionGeneration, let fallback = resolvedTeamID else { return }
        // The account's selection pointed at the deleted team; save the
        // fallback so other devices and the web follow it. Best effort: the
        // local selection is already correct.
        try? await selectTeam(id: fallback)
    }
}

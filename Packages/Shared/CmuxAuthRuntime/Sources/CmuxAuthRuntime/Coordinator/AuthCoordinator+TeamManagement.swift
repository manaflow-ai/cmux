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

    /// Emails a team invitation to each address. The membership changes only when someone
    /// accepts, so the team list is not re-read here.
    func inviteToTeam(id: String, emails: [String], role: CMUXTeamRole = .member) async throws -> CMUXTeamInviteResult {
        guard isAuthenticated else { throw CMUXTeamError.signedOut }
        guard let manager = client as? any TeamManaging else { throw CMUXTeamError.unavailable }
        return try await runPhase(.teamManagement, timeout: timeouts.network) {
            try await manager.inviteToTeam(id: id, emails: emails, role: role)
        }
    }

    /// Pending invitations addressed to the signed-in user's verified emails.
    func receivedTeamInvitations() async throws -> [CMUXReceivedTeamInvitation] {
        guard isAuthenticated else { throw CMUXTeamError.signedOut }
        guard let manager = client as? any TeamManaging else { throw CMUXTeamError.unavailable }
        return try await runPhase(.teamManagement, timeout: timeouts.network) {
            try await manager.receivedTeamInvitations()
        }
    }

    /// Joins the team a received invitation names, re-reads the membership list, and makes the
    /// joined team active, as the server already saved it as the account's selection.
    /// - Returns: The joined team's id and the role in it.
    @discardableResult
    func acceptTeamInvitation(id: String) async throws -> CMUXTeamJoin {
        guard isAuthenticated else { throw CMUXTeamError.signedOut }
        guard let manager = client as? any TeamManaging else { throw CMUXTeamError.unavailable }
        let generation = sessionGeneration
        // A team-list read already in flight answers without the joined team.
        teamListGeneration &+= 1
        let joined = try await runPhase(.teamManagement, timeout: timeouts.network) {
            try await manager.acceptTeamInvitation(id: id)
        }
        guard generation == sessionGeneration, isAuthenticated else { throw CMUXTeamError.signedOut }
        // A team-list read that started while the accept ran may have read the list before the
        // join: it must not land over the re-read below.
        teamListGeneration &+= 1
        await refreshTeams()
        // The membership is already written; a failed local selection leaves the person in the
        // team with their previous team active, which the team picker can change.
        if generation == sessionGeneration, availableTeams.contains(where: { $0.id == joined.teamID }) {
            try? await selectTeam(id: joined.teamID)
        }
        return joined
    }

    /// Declines a received invitation; the membership does not change.
    func declineTeamInvitation(id: String) async throws {
        guard isAuthenticated else { throw CMUXTeamError.signedOut }
        guard let manager = client as? any TeamManaging else { throw CMUXTeamError.unavailable }
        try await runPhase(.teamManagement, timeout: timeouts.network) {
            try await manager.declineTeamInvitation(id: id)
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
        // A team-list read already in flight answers with the old name.
        teamListGeneration &+= 1
        let renamed = try await runPhase(.teamManagement, timeout: timeouts.network) {
            try await manager.renameTeam(id: id, displayName: name.value)
        }
        guard generation == sessionGeneration, isAuthenticated else { throw CMUXTeamError.signedOut }
        teamListGeneration &+= 1
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
        guard !isSelectingTeam, !isCreatingTeam, !isDeletingTeam else { throw CMUXTeamError.busy }
        // No switch or create starts until the delete and its fallback selection are saved.
        isDeletingTeam = true
        defer { isDeletingTeam = false }
        let generation = sessionGeneration
        let wasActive = resolvedTeamID == id
        // A team-list read already in flight answers with the team still in it,
        // and its selection may name the deleted team.
        teamListGeneration &+= 1
        teamMutationGeneration &+= 1
        try await runPhase(.teamManagement, timeout: timeouts.network) {
            try await manager.deleteTeam(id: id)
        }
        guard generation == sessionGeneration, isAuthenticated else { throw CMUXTeamError.signedOut }
        teamListGeneration &+= 1
        teamMutationGeneration &+= 1
        availableTeams.removeAll { $0.id == id }
        if wasActive { selectedTeamID = availableTeams.first?.id }
        await refreshTeams()
        guard wasActive, generation == sessionGeneration, let fallback = resolvedTeamID else { return }
        // The account's selection pointed at the deleted team; save the
        // fallback so other devices and the web follow it. Best effort: the
        // local selection is already correct.
        try? await persistDeleteFallback(id: fallback)
    }
}

import CMUXAuthCore

public extension AuthCoordinator {
    /// Persist a team selection on Stack Auth before changing the local
    /// projection. Every UI surface uses this action so a rejected request
    /// leaves the current cloud scope and open work untouched.
    /// - Parameter id: A team id from ``availableTeams``.
    func selectTeam(id: String?) async throws {
        if let id, !availableTeams.contains(where: { $0.id == id }) {
            throw AuthClientError.teamNotAvailable
        }
        try await client.setSelectedTeam(id: id)
        selectedTeamID = id
    }

    /// Creates a team, refreshes membership, and selects the new team.
    /// - Parameter displayName: The display name entered by the user.
    /// - Returns: The authoritative newly-created team.
    func createTeam(displayName: String) async throws -> CMUXAuthTeam {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AuthClientError.invalidTeamName }
        guard isAuthenticated else { throw AuthError.unauthorized }
        let generation = sessionGeneration
        let created = try await client.createTeam(displayName: trimmed)
        guard generation == sessionGeneration, isAuthenticated else {
            throw AuthError.unauthorized
        }
        var refreshed = try await client.listTeams()
        if !refreshed.contains(where: { $0.id == created.id }) {
            refreshed.append(created)
        }
        availableTeams = refreshed
        try await selectTeam(id: created.id)
        return created
    }
}

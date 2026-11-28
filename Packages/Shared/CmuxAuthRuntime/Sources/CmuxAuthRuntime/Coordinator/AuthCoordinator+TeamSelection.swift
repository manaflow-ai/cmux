public import CMUXAuthCore
import Foundation

public extension AuthCoordinator {
    /// Persist a team selection on Stack Auth before changing the local
    /// projection. Every UI surface uses this action so a rejected request
    /// leaves the current cloud scope and open work untouched. The persistence
    /// request is bounded by the coordinator's network timeout.
    /// - Parameter id: A team id from ``availableTeams``.
    func selectTeam(id: String?) async throws {
        guard !isCreatingTeam else {
            throw AuthTeamChangeInProgressError()
        }
        if let id, !availableTeams.contains(where: { $0.id == id }) {
            throw AuthClientError.teamNotAvailable
        }
        try await persistTeamSelection(id: id)
    }

    /// Persists a selection that is already owned by a higher-level team
    /// mutation. ``createTeam(displayName:)`` uses this after it has created
    /// and listed the new team while retaining the create's exclusion claim.
    private func persistTeamSelection(id: String?) async throws {
        let requestID = UUID()
        activeTeamSwitches.insert(requestID)
        isSelectingTeam = true
        defer {
            activeTeamSwitches.remove(requestID)
            isSelectingTeam = !activeTeamSwitches.isEmpty
        }
        teamMutationGeneration &+= 1
        let mutationGeneration = teamMutationGeneration
        let sessionGeneration = self.sessionGeneration
        let client = self.client
        try await runPhase(.teamSelection, timeout: timeouts.network) {
            try await client.setSelectedTeam(id: id)
        }
        guard sessionGeneration == self.sessionGeneration,
              mutationGeneration == teamMutationGeneration,
              isAuthenticated else {
            throw AuthError.unauthorized
        }
        selectedTeamID = id
    }

    /// Creates a team, refreshes membership, and selects the new team.
    /// - Parameter displayName: The display name entered by the user.
    /// - Returns: The authoritative newly-created team.
    func createTeam(displayName: String) async throws -> CMUXAuthTeam {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AuthClientError.invalidTeamName }
        guard isAuthenticated else { throw AuthError.unauthorized }
        guard !isSelectingTeam, !isCreatingTeam else {
            throw AuthTeamChangeInProgressError()
        }
        isCreatingTeam = true
        defer { isCreatingTeam = false }
        teamMutationGeneration &+= 1
        let mutationGeneration = teamMutationGeneration
        let generation = sessionGeneration
        let client = self.client
        let created = try await runPhase(.teamSelection, timeout: timeouts.network) {
            try await client.createTeam(displayName: trimmed)
        }
        guard generation == sessionGeneration,
              mutationGeneration == teamMutationGeneration,
              isAuthenticated else {
            throw AuthError.unauthorized
        }
        var refreshed = try await runPhase(.listTeams, timeout: timeouts.network) {
            try await client.listTeams()
        }
        guard generation == sessionGeneration,
              mutationGeneration == teamMutationGeneration,
              isAuthenticated else {
            throw AuthError.unauthorized
        }
        if !refreshed.contains(where: { $0.id == created.id }) {
            refreshed.append(created)
        }
        availableTeams = refreshed
        try await persistTeamSelection(id: created.id)
        return created
    }

    /// Re-reads team membership from Stack Auth after a membership change made
    /// outside the selection path (leaving a team, an invitation accepted in
    /// the browser). Keeps the current selection when it is still a member
    /// team and falls back like sign-in does otherwise.
    func refreshTeams() async {
        guard isAuthenticated else { return }
        await refreshTeams(generation: sessionGeneration)
    }
}

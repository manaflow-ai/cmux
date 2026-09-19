public import CMUXAuthCore
import Foundation

// MARK: - Team membership

public extension AuthCoordinator {
    /// Re-reads the signed-in user's teams from the backend.
    ///
    /// The team list is otherwise loaded once per session, so membership
    /// changes made elsewhere (the web dashboard, another device, being added
    /// to or removed from a team) never reach an already-running app. Callers
    /// that present the team list drive this before showing it.
    ///
    /// Tolerates failure the same way the sign-in refresh does: a flaky fetch
    /// leaves the previously known teams in place rather than emptying the
    /// picker. Writes are dropped when a sign-out or account switch raced the
    /// fetch, so one account's teams can never land on another's session.
    func refreshAvailableTeams() async {
        await refreshTeams(generation: sessionGeneration)
    }

    /// Creates a team, then makes it the active one.
    ///
    /// The team list and the selection are updated from the backend's reply,
    /// not optimistically: a team the backend did not create must never appear
    /// in the picker, and a selection pointing at one would scope cloud reads
    /// to a team the user is not a member of.
    ///
    /// - Parameter displayName: The team's human-readable name. Surrounding
    ///   whitespace is trimmed; an empty name is rejected without a round trip.
    /// - Returns: The created team.
    @discardableResult
    func createTeam(displayName: String) async throws -> CMUXAuthTeam {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AuthError.invalidTeamName }
        guard isAuthenticated else { throw AuthError.unauthorized }

        let generation = sessionGeneration
        let client = self.client
        let created = try await runPhase(.createTeam, timeout: timeouts.network) {
            try await client.createTeam(displayName: trimmed)
        }
        // A sign-out or account switch during the round trip: the team belongs
        // to an account this coordinator no longer represents, so nothing of it
        // may reach the current (possibly signed-out) session's state.
        guard generation == sessionGeneration else { return created }

        // Prefer the backend's own list so membership, ordering, and any
        // server-side normalization of the name are what the picker shows.
        await refreshTeams(generation: generation)
        guard generation == sessionGeneration else { return created }
        if !availableTeams.contains(where: { $0.id == created.id }) {
            // The list read failed or has not caught up. The create call
            // succeeded, so the team exists and the user is its creator;
            // showing it is correct and the next refresh reconciles.
            authenticatedTeamsSessionGeneration = generation
            availableTeams.append(created)
        }
        selectedTeamID = created.id
        return created
    }
}

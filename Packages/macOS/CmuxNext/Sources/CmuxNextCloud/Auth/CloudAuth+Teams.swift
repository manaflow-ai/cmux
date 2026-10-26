public import CMUXAuthCore
import CmuxAuthRuntime
import Foundation

/// Team management for Settings > Accounts, through the coordinator so the
/// team list, the active team and everything that follows the team change
/// together. Failures are `CMUXTeamError`.
extension CloudAuth {
    public func teamMemberships() async throws -> CMUXTeamMemberships {
        try await coordinator.teamMemberships()
    }

    public func teamDetail(id: String) async throws -> CMUXTeamDetail {
        try await coordinator.teamDetail(id: id)
    }

    /// Creates a team and makes it the active team.
    public func createTeam(named name: String) async throws -> CMUXAuthTeam {
        do {
            return try await coordinator.createTeam(displayName: try CMUXTeamName(name).value)
        } catch is AuthTeamChangeInProgressError {
            throw CMUXTeamError.busy
        }
    }

    public func renameTeam(id: String, to name: String) async throws {
        try await coordinator.renameTeam(id: id, displayName: name)
    }

    /// Deletes a team; when it was the active team, another becomes active.
    public func deleteTeam(id: String) async throws {
        try await coordinator.deleteTeam(id: id)
    }
}

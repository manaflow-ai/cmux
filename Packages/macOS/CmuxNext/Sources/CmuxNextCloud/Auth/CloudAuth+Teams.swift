public import CMUXAuthCore
import CmuxAuthRuntime
import Foundation

/// Team management for Settings > Accounts, through the coordinator so the
/// team list, the active team and everything that follows the team change
/// together. Every failure is a `CMUXTeamError` (a session that ended
/// mid-change is `signedOut`, another team change still running is `busy`).
extension CloudAuth {
    public func teamMemberships() async throws -> CMUXTeamMemberships {
        try await Self.teamErrors { try await coordinator.teamMemberships() }
    }

    public func teamDetail(id: String) async throws -> CMUXTeamDetail {
        try await Self.teamErrors { try await coordinator.teamDetail(id: id) }
    }

    /// Creates a team and makes it the active team.
    public func createTeam(named name: String) async throws -> CMUXAuthTeam {
        let valid = try CMUXTeamName(name).value
        return try await Self.teamErrors { try await coordinator.createTeam(displayName: valid) }
    }

    public func renameTeam(id: String, to name: String) async throws {
        try await Self.teamErrors { try await coordinator.renameTeam(id: id, displayName: name) }
    }

    /// Deletes a team; when it was the active team, another becomes active.
    public func deleteTeam(id: String) async throws {
        try await Self.teamErrors { try await coordinator.deleteTeam(id: id) }
    }

    private static func teamErrors<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch is AuthTeamChangeInProgressError {
            throw CMUXTeamError.busy
        } catch AuthError.unauthorized {
            throw CMUXTeamError.signedOut
        }
    }
}

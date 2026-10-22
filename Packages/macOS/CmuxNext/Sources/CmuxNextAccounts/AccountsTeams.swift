public import CMUXAuthCore
public import CmuxNextCloud
import Foundation
import Observation

/// The demo account's teams for ``MockAccountsServices``: Personal (active) and Acme.
@MainActor @Observable
final class MockTeamSource: ActiveTeamSource {
    var isAuthenticated = true
    var availableTeams = [CMUXAuthTeam(id: "team-personal", displayName: "Personal"), CMUXAuthTeam(id: "team-acme", displayName: "Acme")]
    var selectedTeamID: String? = "team-personal"
    var failure: (any Error)?

    var resolvedTeamID: String? { selectedTeamID ?? availableTeams.first?.id }

    func selectTeam(id: String?) async throws {
        if let failure { throw failure }
        selectedTeamID = id
    }

    func refreshTeams() async {}
}

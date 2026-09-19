import CMUXAuthCore
import CmuxAuthRuntime
import CmuxSettingsUI
import Observation

extension HostAccountFlow {
    /// Re-emits coordinator changes through this app-facing projection so
    /// SwiftUI consumers observe team membership without holding the runtime
    /// coordinator directly.
    func startCoordinatorObservation() {
        observeCoordinator()
    }

    private func observeCoordinator() {
        withObservationTracking {
            _ = coordinator.currentUser
            _ = coordinator.availableTeams
            _ = coordinator.selectedTeamID
            _ = coordinator.isAuthenticated
            _ = coordinator.isLoading
            _ = coordinator.isRestoringSession
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.teamObservationRevision &+= 1
                self.observeCoordinator()
            }
        }
    }

    /// Persists a team selection through the shared coordinator action.
    func selectTeam(id: String?) async throws {
        try await coordinator.selectTeam(id: id)
    }

    /// Creates a team through Stack Auth and makes it the active team.
    func createTeam(displayName: String) async throws -> AccountTeamSummary {
        let team = try await coordinator.createTeam(displayName: displayName)
        return AccountTeamSummary(id: team.id, displayName: team.displayName, slug: team.slug)
    }

    /// The active team label used by the sidebar account surface.
    var activeTeamDisplayName: String? {
        _ = teamObservationRevision
        guard let id = coordinator.resolvedTeamID else { return nil }
        return coordinator.availableTeams.first(where: { $0.id == id })?.displayName
    }

    /// The compact account subtitle shown in the sidebar footer and popover.
    var sidebarTeamSubtitle: String {
        _ = teamObservationRevision
        let team = activeTeamDisplayName
            ?? String(localized: "sidebar.account.noTeam", defaultValue: "No team")
        if isProActive {
            return String(
                format: String(localized: "sidebar.account.teamWithPlan", defaultValue: "%1$@ · Pro"),
                team
            )
        }
        return team
    }
}

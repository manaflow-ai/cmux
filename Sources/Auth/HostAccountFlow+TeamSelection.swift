import CMUXAuthCore
import CmuxAuthRuntime
import CmuxSettingsUI
import Foundation
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
            _ = coordinator.isSelectingTeam
            _ = coordinator.isCreatingTeam
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

    /// Projects pending selection immediately; a rejected request restores the
    /// confirmed selection by clearing only this request's pending projection.
    /// A switch during a team create is refused, since it would fail the
    /// create after the server made the team. A later switch still replaces
    /// a pending one.
    func selectTeam(id: String?) async throws {
        let requestID = UUID()
        pendingTeamSelection = (requestID, id)
        defer {
            if pendingTeamSelection?.requestID == requestID { pendingTeamSelection = nil }
        }
        do {
            try await coordinator.selectTeam(id: id)
        } catch {
            // Re-emit even for a synchronous rejection so a Settings picker
            // returns from its requested value to this flow's projection.
            teamObservationRevision &+= 1
            throw error
        }
    }

    /// Creates a team through Stack Auth and makes it the active team. Refused
    /// while a switch or another create is in flight, before it reaches the
    /// server, so neither change fails the other after the server acted.
    /// ``pendingTeamCreate`` stands for the team until the server answers; by
    /// then the coordinator has selected the new team, or kept the previous one.
    func createTeam(displayName: String) async throws -> AccountTeamSummary {
        // Admission belongs to the coordinator. While it is still busy, a
        // second request must neither replace nor clear the active projection.
        // Once the coordinator has finished, a new request may claim a fresh
        // projection before the previous caller's continuation runs its defer.
        let requestID = UUID()
        let ownsProjection = !coordinator.isCreatingTeam
        if ownsProjection {
            pendingTeamCreateRequestID = requestID
            pendingTeamCreate = PendingTeamCreate(
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                existingTeamIDs: Set(availableTeams.map(\.id))
            )
        }
        defer {
            if ownsProjection, pendingTeamCreateRequestID == requestID {
                pendingTeamCreate = nil
                pendingTeamCreateRequestID = nil
            }
        }
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

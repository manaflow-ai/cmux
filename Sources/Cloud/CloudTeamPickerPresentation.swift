import AppKit
import Observation

/// Transient presentation owned by one Cloud surface, separate from team selection.
@MainActor
@Observable
final class CloudTeamPickerPresentation {
    var isPresented = false
    /// The last failed switch, shown under the header until dismissed or the
    /// menu opens again.
    var switchError: String?

    /// Switches the active team. A pending switch or create blocks it, so two
    /// requests cannot race for the confirmed scope.
    func selectTeam(_ teamID: String, accountFlow: HostAccountFlow) {
        guard teamID != accountFlow.selectedTeamID,
              !accountFlow.isSelectingTeam,
              !accountFlow.isCreatingTeam else { return }
        switchError = nil
        Task { @MainActor in
            do {
                try await accountFlow.selectTeam(id: teamID)
            } catch {
                let message = String(
                    localized: "sidebar.account.switchTeamFailed",
                    defaultValue: "Could not switch teams. Try again."
                )
                switchError = message
                if let application = NSApp {
                    NSAccessibility.post(
                        element: application,
                        notification: .announcementRequested,
                        userInfo: [
                            .announcement: message,
                            .priority: NSAccessibilityPriorityLevel.high.rawValue,
                        ]
                    )
                }
            }
        }
    }
}

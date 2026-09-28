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

    /// Switches the active team. A pending switch blocks it, so two switches
    /// cannot race for the confirmed scope; the account flow refuses a switch
    /// during a team create, which shows the switch error.
    func selectTeam(_ teamID: String, accountFlow: HostAccountFlow) {
        guard teamID != accountFlow.selectedTeamID,
              !accountFlow.isSelectingTeam else { return }
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

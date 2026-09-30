import AppKit
import Observation

/// Transient presentation owned by one Cloud surface, separate from team selection.
@MainActor
@Observable
final class CloudTeamPickerPresentation {
    var isPresented = false
    /// The Invite popover anchored to the header Invite button.
    var isInvitePresented = false
    /// The last failed switch or create, shown under the header until
    /// dismissed or the menu opens again.
    var teamChangeError: String?
    /// The name of the last rejected create, which the next Create Team sheet
    /// starts with so a retry does not mean typing it again.
    private(set) var rejectedTeamName: String?
    /// The Create Team sheet opened from this surface's menu.
    let createTeamSheet = CloudCreateTeamSheetPresenter()

    /// Switches the active team. A pending switch blocks it, so two switches
    /// cannot race for the confirmed scope; the account flow refuses a switch
    /// during a team create, which shows the switch error.
    func selectTeam(_ teamID: String, accountFlow: HostAccountFlow) {
        guard teamID != accountFlow.selectedTeamID,
              !accountFlow.isSelectingTeam else { return }
        teamChangeError = nil
        Task { @MainActor in
            do {
                try await accountFlow.selectTeam(id: teamID)
            } catch {
                report(Self.switchFailedMessage)
            }
        }
    }

    func presentCreateTeamSheet(accountFlow: HostAccountFlow, preferredWindow: NSWindow?) {
        createTeamSheet.present(
            accountFlow: accountFlow,
            initialName: rejectedTeamName ?? "",
            preferredWindow: preferredWindow
        ) { [self] name in
            createTeam(named: name, accountFlow: accountFlow)
        }
    }

    /// Creates a team without waiting on the sheet: the sheet has closed, and
    /// the header shows the new team as active until the server answers. A
    /// rejected create returns the header to the previous team and reports it.
    func createTeam(named displayName: String, accountFlow: HostAccountFlow) {
        teamChangeError = nil
        rejectedTeamName = nil
        let existingTeamIDs = Set(accountFlow.availableTeams.map(\.id))
        Task { @MainActor in
            do {
                _ = try await accountFlow.createTeam(displayName: displayName)
            } catch {
                // The server can create the team and then fail to select it.
                // Retrying the name would make a second team, so that is a
                // failed switch to a team the menu now lists.
                let wasCreated = accountFlow.availableTeams.contains { team in
                    !existingTeamIDs.contains(team.id) && team.displayName == displayName
                }
                if wasCreated {
                    report(Self.switchFailedMessage)
                } else {
                    rejectedTeamName = displayName
                    report(String(
                        localized: "sidebar.account.createTeamFailed",
                        defaultValue: "Could not create that team. Try again."
                    ))
                }
            }
        }
    }

    private static var switchFailedMessage: String {
        String(localized: "sidebar.account.switchTeamFailed", defaultValue: "Could not switch teams. Try again.")
    }

    private func report(_ message: String) {
        teamChangeError = message
        guard let application = NSApp else { return }
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

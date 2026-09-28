import CmuxFoundation
import CmuxSettingsUI
import SwiftUI

/// Shows the active team in the Cloud header and pulls its team menu down from
/// the trigger's leading edge.
struct CloudTeamPickerRow: View {
    let accountFlow: HostAccountFlow
    @Bindable var presentation: CloudTeamPickerPresentation

    private var currentTeam: AccountTeamSummary? {
        accountFlow.availableTeams.first { $0.id == accountFlow.selectedTeamID }
    }

    private var currentTeamName: String {
        currentTeam?.displayName ?? String(localized: "sidebar.account.noTeam", defaultValue: "No team")
    }

    private var helpText: String {
        String(localized: "settings.account.activeTeam", defaultValue: "Active Team")
    }

    var body: some View {
        Button {
            presentation.isPresented = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.2")
                    .font(.system(size: 10, weight: .semibold))
                Text(currentTeamName)
                    .cmuxFont(size: 11, weight: .medium)
                    .lineLimit(1)
                    .layoutPriority(1)
                // A symbol, not ProgressView: a hosted progress indicator
                // splits the button's accessibility element, so VoiceOver and
                // UI tests lose the trigger while a switch is pending.
                if accountFlow.isSelectingTeam {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .symbolEffect(.pulse)
                } else {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay {
            CloudTeamPickerMenuAnchor(
                isPresented: $presentation.isPresented,
                helpText: helpText,
                makeMenu: makeMenu,
                onWillPresent: { presentation.switchError = nil }
            )
        }
        .layoutPriority(1)
        .safeHelp(helpText)
        .accessibilityLabel(teamPickerAccessibilityLabel)
        .accessibilityValue(switchingValue)
        .accessibilityIdentifier("CloudTeamPickerButton")
    }

    private var switchingValue: String {
        guard accountFlow.isSelectingTeam else { return "" }
        return String(localized: "cloud.teamPicker.switching", defaultValue: "Switching teams…")
    }

    /// Built from the state at open time. A switch finishing while the menu is
    /// open shows on the trigger; the next open reflects it.
    private func makeMenu() -> NSMenu {
        CloudTeamPickerMenu.make(
            teams: accountFlow.availableTeams,
            selectedTeamID: accountFlow.selectedTeamID,
            isSwitching: accountFlow.isSelectingTeam,
            onSelect: { [presentation, accountFlow] team in
                presentation.selectTeam(team.id, accountFlow: accountFlow)
            },
            onCreate: { [accountFlow] in
                // Let the menu finish closing before a sheet takes the window.
                DispatchQueue.main.async {
                    CloudCreateTeamSheetPresenter.shared.present(accountFlow: accountFlow)
                }
            }
        )
    }

    private var teamPickerAccessibilityLabel: String {
        String(
            format: String(localized: "sidebar.account.teamRowLabel", defaultValue: "%1$@%2$@"),
            currentTeamName,
            String(localized: "sidebar.account.activeSuffix", defaultValue: ", active")
        )
    }
}

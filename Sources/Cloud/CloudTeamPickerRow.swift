import CmuxSettingsUI
import SwiftUI

/// Shows the active team in the Cloud header and opens its team menu.
struct CloudTeamPickerRow: View {
    let accountFlow: HostAccountFlow
    @Binding var isPresented: Bool

    private var currentTeam: AccountTeamSummary? {
        accountFlow.availableTeams.first { $0.id == accountFlow.selectedTeamID }
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.2")
                    .font(.system(size: 10, weight: .semibold))
                Text(currentTeam?.displayName ?? String(
                    localized: "sidebar.account.noTeam",
                    defaultValue: "No team"
                ))
                .cmuxFont(size: 11, weight: .medium)
                .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            CloudTeamPicker(accountFlow: accountFlow)
        }
        .safeHelp(String(localized: "settings.account.activeTeam", defaultValue: "Active Team"))
        .accessibilityLabel(teamPickerAccessibilityLabel)
        .accessibilityIdentifier("CloudTeamPickerButton")
    }

    private var teamPickerAccessibilityLabel: String {
        let name = currentTeam?.displayName ?? String(
            localized: "sidebar.account.noTeam",
            defaultValue: "No team"
        )
        return String(
            format: String(localized: "sidebar.account.teamRowLabel", defaultValue: "%1$@%2$@"),
            name,
            String(localized: "sidebar.account.activeSuffix", defaultValue: ", active")
        )
    }
}

import CmuxAppKitSupportUI
import CmuxSettingsUI
import SwiftUI

/// Opens the team submenu on hover, click, or keyboard activation.
struct SidebarAccountTeamPickerRow: View {
    let accountFlow: HostAccountFlow
    @Binding var isPresented: Bool
    let popoverGroup: CmuxPopoverGroup

    private var currentTeam: AccountTeamSummary? {
        accountFlow.availableTeams.first { $0.id == accountFlow.selectedTeamID }
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 8) {
                Label(currentTeam?.displayName ?? String(
                    localized: "sidebar.account.noTeam",
                    defaultValue: "No team"
                ), systemImage: "person.2")
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(SidebarAccountMenuButtonStyle())
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { isPresented = true }
        }
        .overlay(alignment: .trailing) {
            ArrowlessPopoverAnchor(
                isPresented: $isPresented,
                preferredEdge: .maxX,
                detachedGap: 4,
                presentationAnimation: .enabled,
                group: popoverGroup
            ) {
                SidebarAccountTeamPicker(accountFlow: accountFlow)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
        .accessibilityLabel(teamPickerAccessibilityLabel)
        .accessibilityHint(String(
            localized: "settings.account.activeTeam",
            defaultValue: "Active Team"
        ))
        .accessibilityIdentifier("SidebarAccountTeamPickerButton")
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

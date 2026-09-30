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

    /// A pending create shows its team as active until the server answers.
    private var currentTeamName: String {
        accountFlow.pendingTeamCreate?.displayName
            ?? currentTeam?.displayName
            ?? String(localized: "sidebar.account.noTeam", defaultValue: "No team")
    }

    private var pendingStatus: String? {
        if accountFlow.isCreatingTeam {
            return String(localized: "cloud.teamPicker.creating", defaultValue: "Creating team…")
        }
        if accountFlow.isSelectingTeam {
            return String(localized: "cloud.teamPicker.switching", defaultValue: "Switching teams…")
        }
        return nil
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
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .contentShape(RoundedRectangle(cornerRadius: RightSidebarChromeMetrics.buttonCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay {
            CloudTeamPickerMenuAnchor(
                isPresented: $presentation.isPresented,
                helpText: helpText,
                makeMenu: makeMenu,
                onWillPresent: { presentation.teamChangeError = nil }
            )
        }
        .layoutPriority(1)
        .safeHelp(helpText)
        .accessibilityLabel(teamPickerAccessibilityLabel)
        .accessibilityValue(pendingStatus ?? "")
        .accessibilityIdentifier("CloudTeamPickerButton")
    }

    /// Built from the state at open time. A change finishing while the menu is
    /// open shows on the trigger; the next open reflects it.
    private func makeMenu(from anchor: CloudTeamPickerMenuAnchorView) -> NSMenu {
        let window = anchor.window
        return CloudTeamPickerMenu.make(
            teams: accountFlow.availableTeams,
            selectedTeamID: accountFlow.selectedTeamID,
            isSwitching: accountFlow.isSelectingTeam,
            pendingCreate: accountFlow.pendingTeamCreate,
            onSelect: { [presentation, accountFlow] team in
                presentation.selectTeam(team.id, accountFlow: accountFlow)
            },
            onCreate: { [weak anchor, presentation, accountFlow] in
                // The sheet waits for the menu's tracking loop to return.
                let present: @MainActor () -> Void = {
                    presentation.presentCreateTeamSheet(accountFlow: accountFlow, preferredWindow: window)
                }
                if let anchor {
                    anchor.afterDismiss(present)
                } else {
                    present()
                }
            },
            onInvite: { [weak anchor, presentation] in
                let present: @MainActor () -> Void = { presentation.isInvitePresented = true }
                if let anchor { anchor.afterDismiss(present) } else { present() }
            },
            onMembers: { [weak anchor, accountFlow] in
                let present: @MainActor () -> Void = { accountFlow.showTeamMembers(focusInvite: false) }
                if let anchor { anchor.afterDismiss(present) } else { present() }
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

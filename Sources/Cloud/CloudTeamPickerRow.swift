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

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontMagnification

    var body: some View {
        Button {
            presentation.isPresented = true
        } label: {
            // The AppKit anchor hosts the visible copy because it owns pointer
            // and window lifecycle. This transparent copy keeps the button's
            // intrinsic size, keyboard action, and accessibility element.
            chipLabel(isHighlighted: false)
                .opacity(0)
        }
        .buttonStyle(.plain)
        .overlay {
            CloudTeamPickerMenuAnchor(
                isPresented: $presentation.isPresented,
                helpText: helpText,
                makeChip: { [currentTeamName, isEnabled, layoutDirection, globalFontMagnification] isHighlighted in
                    AnyView(
                        chipLabel(
                            teamName: currentTeamName,
                            isEnabled: isEnabled,
                            isHighlighted: isHighlighted
                        )
                        .environment(\.layoutDirection, layoutDirection)
                        .environment(\.cmuxGlobalFontMagnificationPercent, globalFontMagnification)
                    )
                },
                makeMenu: makeMenu,
                onWillPresent: {
                    presentation.teamChangeError = nil
                    // The menu is built from the current list; a stale list
                    // is refreshed for the next open.
                    Task { await accountFlow.refreshReceivedInvitations(notify: false) }
                }
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
            },
            invitations: accountFlow.receivedInvitations.map { .init(id: $0.id, teamName: $0.teamName) },
            onJoin: { [presentation, accountFlow] invitation in
                presentation.joinInvitation(invitation.id, accountFlow: accountFlow)
            },
            accountEmail: accountFlow.currentIdentity?.email,
            onSwitchAccount: { [weak anchor, accountFlow] in
                let switchAccount: @MainActor () -> Void = { Task { await accountFlow.switchAccount() } }
                if let anchor { anchor.afterDismiss(switchAccount) } else { switchAccount() }
            },
            onSignOut: { [weak anchor, accountFlow] in
                let signOut: @MainActor () -> Void = { Task { await accountFlow.signOut() } }
                if let anchor { anchor.afterDismiss(signOut) } else { signOut() }
            }
        )
    }

    private func chipLabel(isHighlighted: Bool) -> some View {
        chipLabel(teamName: currentTeamName, isEnabled: isEnabled, isHighlighted: isHighlighted)
    }

    private func chipLabel(teamName: String, isEnabled: Bool, isHighlighted: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "person.2")
                .font(.system(size: 10, weight: .semibold))
            Text(teamName)
                .cmuxFont(size: 11, weight: .medium)
                .lineLimit(1)
                .layoutPriority(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
        }
        // Same grey and hover rule as the tab bar's mode labels above.
        .foregroundColor(
            RightSidebarChromeControlStyle.pillForegroundColor(
                isSelected: false,
                isHovered: isEnabled && isHighlighted
            )
        )
        // Flush with the tree's section chevrons below.
        .padding(.leading, 1)
        .padding(.trailing, 7)
        .frame(height: 22)
        // The Invite button's fill, starting where the tree's row
        // highlights start so the chip keeps its alignment with the tree.
        .background(
            RoundedRectangle(cornerRadius: RightSidebarChromeMetrics.buttonCornerRadius, style: .continuous)
                .fill(Color.primary.opacity(isEnabled && isHighlighted ? 0.08 : 0))
                .frame(height: 20)
                .padding(.leading, -CloudTreeHoverStyle.leadingOutset)
        )
        .contentShape(RoundedRectangle(cornerRadius: RightSidebarChromeMetrics.buttonCornerRadius, style: .continuous))
    }

    private var teamPickerAccessibilityLabel: String {
        String(
            format: String(localized: "sidebar.account.teamRowLabel", defaultValue: "%1$@%2$@"),
            currentTeamName,
            String(localized: "sidebar.account.activeSuffix", defaultValue: ", active")
        )
    }
}

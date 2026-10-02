import AppKit
import CmuxCloud
import CmuxFoundation
import SwiftUI

/// Where the Cloud header puts Refresh and New Machine.
enum CloudHeaderMachineActions {
    /// Two icon buttons beside the full team name.
    case inline
    /// One "⋯" menu, so the team name keeps its room in a narrow sidebar.
    case overflowMenu
}

/// Team scope, Invite, and machine actions share the Cloud header. Fleet status keeps its own
/// row so it cannot squeeze the active team's name out of a narrow sidebar;
/// the status view owns that row, so an idle fleet adds no gap under the toolbar.
struct CloudTeamPickerHeader<AgentMenu: View, Status: View>: View {
    let accountFlow: HostAccountFlow?
    let presentation: CloudTeamPickerPresentation?
    let chromeBackgroundColor: NSColor
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onNewMachine: () -> Void
    @ViewBuilder let agentMenu: () -> AgentMenu
    @ViewBuilder let status: () -> Status
    @State private var panePresentation = CloudTeamPickerPresentation()

    var body: some View {
        let picker = presentation ?? panePresentation
        VStack(spacing: 0) {
            // The first row that fits wins, so a narrow sidebar folds Refresh
            // and New Machine into one menu before it squeezes the team name.
            ViewThatFits(in: .horizontal) {
                actionsRow(.inline, picker: picker)
                actionsRow(.overflowMenu, picker: picker)
            }
            .frame(maxWidth: .infinity)
            .rightSidebarChromeBar()
            .rightSidebarChromeBottomBorder(backgroundColor: chromeBackgroundColor)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("CloudMachinesSectionHeader")
            if let teamChangeError = picker.teamChangeError {
                teamChangeErrorRow(teamChangeError) { picker.teamChangeError = nil }
            }
            status()
        }
        .onDisappear {
            picker.isPresented = false
            picker.isInvitePresented = false
        }
    }

    /// One candidate header row. Internal so tests can measure each candidate
    /// the way `ViewThatFits` does, without an accessibility client.
    @ViewBuilder
    func actionsRow(_ actions: CloudHeaderMachineActions, picker presentation: CloudTeamPickerPresentation) -> some View {
        @Bindable var picker = presentation
        HStack(spacing: 6) {
            if let accountFlow {
                switch actions {
                case .inline:
                    CloudTeamPickerRow(accountFlow: accountFlow, presentation: picker)
                        .fixedSize(horizontal: true, vertical: false)
                        .disabled(accountFlow.isWorkingOnAuth)
                case .overflowMenu:
                    CloudTeamPickerRow(accountFlow: accountFlow, presentation: picker)
                        .disabled(accountFlow.isWorkingOnAuth)
                }
            }
            Spacer(minLength: 0)
            agentMenu()
            if let accountFlow, accountFlow.confirmedTeamID != nil {
                MachinesChromeLabelButton(
                    symbolName: "person.badge.plus",
                    title: String(localized: "sidebar.account.invite.button", defaultValue: "Invite"),
                    accessibilityLabel: String(localized: "sidebar.account.invitePeople.short", defaultValue: "Invite People"),
                    action: { picker.isInvitePresented = true }
                )
                .popover(isPresented: $picker.isInvitePresented, arrowEdge: .bottom) {
                    CloudTeamInvitePopover(accountFlow: accountFlow, presentation: picker)
                }
                .accessibilityIdentifier("CloudTeamInviteButton")
            }
            switch actions {
            case .inline:
                MachinesChromeIconButton(
                    symbolName: "arrow.clockwise",
                    accessibilityLabel: refreshLabel,
                    isBusy: isRefreshing,
                    action: onRefresh
                )
                .accessibilityIdentifier("CloudHeaderRefreshButton")
                MachinesChromeIconButton(
                    symbolName: "plus",
                    accessibilityLabel: newMachineLabel,
                    isBusy: false,
                    action: onNewMachine
                )
                .accessibilityIdentifier("CloudHeaderNewMachineButton")
            case .overflowMenu:
                machineActionsMenu
            }
        }
    }

    private var refreshLabel: String {
        String(localized: "machines.refresh", defaultValue: "Refresh Machines")
    }

    private var newMachineLabel: String {
        String(localized: "machines.new", defaultValue: "New Machine")
    }

    private var machineActionsMenu: some View {
        Menu {
            Button {
                onRefresh()
            } label: {
                Text(refreshLabel)
            }
            .help(refreshLabel)
            .accessibilityLabel(refreshLabel)

            Button {
                onNewMachine()
            } label: {
                Text(newMachineLabel)
            }
            .help(newMachineLabel)
            .accessibilityLabel(newMachineLabel)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22, height: 20)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("CloudMachinesActionsMenu")
    }

    private func teamChangeErrorRow(_ message: String, onDismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10, weight: .semibold))
            Text(message)
                .cmuxFont(size: 11)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("CloudTeamPickerError")
            Spacer(minLength: 0)
            CloudBannerDismissButton(action: onDismiss)
        }
        .foregroundColor(.orange.opacity(0.9))
        .help(message)
        .cloudErrorCopyMenu(message)
        // Without its own container, the row's help and copy menu let the
        // panel's RightSidebar identifier replace the message's and Close's.
        .accessibilityElement(children: .contain)
        .padding(.horizontal, RightSidebarChromeMetrics.barHorizontalPadding)
        .padding(.top, RightSidebarChromeMetrics.barVerticalPadding)
    }
}

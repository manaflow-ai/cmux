import AppKit
import CmuxCloud
import CmuxFoundation
import SwiftUI

/// Team scope and machine actions share the Cloud header. Fleet status keeps its
/// own row so it cannot squeeze the active team's name out of a narrow sidebar;
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
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    if let accountFlow {
                        CloudTeamPickerRow(accountFlow: accountFlow, presentation: picker)
                            .fixedSize(horizontal: true, vertical: false)
                            .disabled(accountFlow.isWorkingOnAuth)
                    }
                    Spacer(minLength: 0)
                    agentMenu()
                    MachinesChromeIconButton(
                        symbolName: "arrow.clockwise",
                        accessibilityLabel: refreshLabel,
                        isBusy: isRefreshing,
                        action: onRefresh
                    )
                    MachinesChromeIconButton(
                        symbolName: "plus",
                        accessibilityLabel: newMachineLabel,
                        isBusy: false,
                        action: onNewMachine
                    )
                }
                HStack(spacing: 6) {
                    if let accountFlow {
                        CloudTeamPickerRow(accountFlow: accountFlow, presentation: picker)
                            .disabled(accountFlow.isWorkingOnAuth)
                    }
                    Spacer(minLength: 0)
                    agentMenu()
                    machineActionsMenu
                }
            }
            .rightSidebarChromeBar()
            .rightSidebarChromeBottomBorder(backgroundColor: chromeBackgroundColor)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("CloudMachinesSectionHeader")
            if let teamChangeError = picker.teamChangeError {
                teamChangeErrorRow(teamChangeError) { picker.teamChangeError = nil }
            }
            status()
        }
        .onDisappear { picker.isPresented = false }
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

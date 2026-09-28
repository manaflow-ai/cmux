import AppKit
import CmuxCloud
import CmuxFoundation
import SwiftUI

/// Team scope and machine actions share the Cloud header. Fleet status keeps its
/// own row so it cannot squeeze the active team's name out of a narrow sidebar.
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
            HStack(spacing: 6) {
                if let accountFlow {
                    CloudTeamPickerRow(accountFlow: accountFlow, presentation: picker)
                        .disabled(accountFlow.isWorkingOnAuth)
                }
                Spacer(minLength: 0)
                agentMenu()
                MachinesChromeIconButton(
                    symbolName: "arrow.clockwise",
                    accessibilityLabel: String(localized: "machines.refresh", defaultValue: "Refresh Machines"),
                    isBusy: isRefreshing,
                    action: onRefresh
                )
                MachinesChromeIconButton(
                    symbolName: "plus",
                    accessibilityLabel: String(localized: "machines.new", defaultValue: "New Machine"),
                    isBusy: false,
                    action: onNewMachine
                )
            }
            .rightSidebarChromeBar()
            .rightSidebarChromeBottomBorder(backgroundColor: chromeBackgroundColor)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("CloudMachinesSectionHeader")
            if let switchError = picker.switchError {
                switchErrorRow(switchError) { picker.switchError = nil }
            }
            HStack(spacing: 6) {
                status()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .onDisappear { picker.isPresented = false }
    }

    private func switchErrorRow(_ message: String, onDismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10, weight: .semibold))
            Text(message)
                .cmuxFont(size: 11)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            CloudBannerDismissButton(action: onDismiss)
        }
        .foregroundColor(.orange.opacity(0.9))
        .help(message)
        .cloudErrorCopyMenu(message)
        // The row's help and copy menu hide the message's own identifier, so
        // the row is the element VoiceOver and UI tests reach, with the
        // message and Close inside it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CloudTeamPickerSwitchError")
        .padding(.horizontal, 10)
        .padding(.top, 4)
    }
}

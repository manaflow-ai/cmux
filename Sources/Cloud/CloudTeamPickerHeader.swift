import AppKit
import CmuxCloud
import CmuxFoundation
import SwiftUI

/// Team scope and Invite share the Cloud header. Fleet status keeps its own
/// row so it cannot squeeze the active team's name out of a narrow sidebar;
/// the status view owns that row, so an idle fleet adds no gap under the toolbar.
struct CloudTeamPickerHeader<Status: View>: View {
    let accountFlow: HostAccountFlow?
    let presentation: CloudTeamPickerPresentation?
    let chromeBackgroundColor: NSColor
    @ViewBuilder let status: () -> Status
    @State private var panePresentation = CloudTeamPickerPresentation()

    var body: some View {
        @Bindable var picker = presentation ?? panePresentation
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if let accountFlow {
                    CloudTeamPickerRow(accountFlow: accountFlow, presentation: picker)
                        .fixedSize(horizontal: true, vertical: false)
                        .disabled(accountFlow.isWorkingOnAuth)
                }
                Spacer(minLength: 0)
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
        .onDisappear {
            picker.isPresented = false
            picker.isInvitePresented = false
        }
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

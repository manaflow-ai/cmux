import AppKit
import SwiftUI

/// Team scope and machine actions share the Cloud header. Fleet status keeps its
/// own row so it cannot squeeze the active team's name out of a narrow sidebar;
/// the status view owns that row, so an idle fleet adds no gap under the toolbar.
struct CloudTeamPickerHeader<OverflowMenu: View, Status: View>: View {
    let accountFlow: HostAccountFlow?
    let presentation: CloudTeamPickerPresentation?
    let chromeBackgroundColor: NSColor
    let onNewMachine: () -> Void
    /// The `⋯` menu: refresh, Cloud Agent launchers and other rare actions.
    @ViewBuilder let overflowMenu: () -> OverflowMenu
    @ViewBuilder let status: () -> Status
    @State private var panePresentation = CloudTeamPickerPresentation()

    var body: some View {
        @Bindable var picker = presentation ?? panePresentation
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if let accountFlow {
                    CloudTeamPickerRow(accountFlow: accountFlow, isPresented: $picker.isPresented)
                        .disabled(accountFlow.isWorkingOnAuth)
                }
                Spacer(minLength: 0)
                if let accountFlow, accountFlow.confirmedTeamID != nil {
                    MachinesChromeLabelButton(
                        symbolName: "person.badge.plus",
                        title: String(localized: "sidebar.account.invite.button", defaultValue: "Invite"),
                        accessibilityLabel: String(localized: "sidebar.account.invitePeople.short", defaultValue: "Invite People"),
                        action: { accountFlow.showTeamInvite() }
                    )
                    .accessibilityIdentifier("CloudTeamInviteButton")
                }
                MachinesChromeIconButton(
                    symbolName: "plus",
                    accessibilityLabel: String(localized: "machines.new", defaultValue: "New Machine"),
                    isBusy: false,
                    action: onNewMachine
                )
                overflowMenu()
            }
            .rightSidebarChromeBar()
            .rightSidebarChromeBottomBorder(backgroundColor: chromeBackgroundColor)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("CloudMachinesSectionHeader")
            HStack(spacing: 6) {
                status()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .onDisappear { picker.isPresented = false }
    }
}

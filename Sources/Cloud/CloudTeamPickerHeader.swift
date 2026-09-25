import AppKit
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
        @Bindable var picker = presentation ?? panePresentation
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if let accountFlow {
                    CloudTeamPickerRow(accountFlow: accountFlow, isPresented: $picker.isPresented)
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

import CmuxMobileSupport
import SwiftUI

#if os(iOS)
/// First-connection state shown after an authoritative empty registry response.
struct DisconnectedRegistryEmptyView: View {
    let isRefreshing: Bool
    let addComputer: () -> Void
    let showSetupHelp: () -> Void
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.devices.emptyTitle", defaultValue: "No devices"),
                systemImage: "desktopcomputer.and.iphone"
            )
        } description: {
            Text(L10n.string(
                "mobile.devices.emptyDescription",
                defaultValue: "Add a computer to start syncing terminal workspaces."
            ))
        } actions: {
            Button(action: addComputer) {
                Text(L10n.string("mobile.addDevice.title", defaultValue: "Add Computer"))
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .accessibilityIdentifier("MobileShowAddDeviceButton")
            Button(action: retry) {
                Text(L10n.string("mobile.common.retry", defaultValue: "Retry"))
            }
            .disabled(isRefreshing)
            Button(action: showSetupHelp) {
                Text(L10n.string("mobile.devices.setupHelp", defaultValue: "Trouble connecting?"))
            }
            .font(.callout)
            .accessibilityIdentifier("MobileDisconnectedSetupHelpButton")
        }
    }
}
#endif

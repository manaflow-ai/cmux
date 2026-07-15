import CmuxMobileSupport
import SwiftUI

#if os(iOS)
struct DisconnectedRegistryUnavailableView: View {
    let isRefreshing: Bool
    let retry: () -> Void
    let addComputer: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.registry.unavailable.title", defaultValue: "Session Discovery Unavailable"),
                systemImage: "wifi.exclamationmark"
            )
        } description: {
            Text(L10n.string(
                "mobile.registry.unavailable.message",
                defaultValue: "We couldn't load available computers and sessions. Check your connection and try again."
            ))
        } actions: {
            Button(action: retry) {
                Text(L10n.string("mobile.common.retry", defaultValue: "Retry"))
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRefreshing)
            Button(action: addComputer) {
                Text(L10n.string("mobile.computers.add", defaultValue: "Add Computer"))
            }
        }
    }
}

struct DisconnectedRegistryAuthenticationRequiredView: View {
    let isRefreshing: Bool
    let retry: () -> Void
    let switchAccount: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.handoff.auth.title", defaultValue: "Session Discovery Unavailable"),
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
        } description: {
            Text(L10n.string(
                "mobile.handoff.auth.message",
                defaultValue: "We couldn't verify your cmux account for session discovery. Try again, or sign out and sign back in."
            ))
        } actions: {
            Button(action: retry) {
                Text(L10n.string("mobile.common.retry", defaultValue: "Retry"))
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRefreshing)
            Button(action: switchAccount) {
                Text(L10n.string(
                    "mobile.recovery.switchAccount",
                    defaultValue: "Sign Out & Switch Account"
                ))
            }
            .accessibilityIdentifier("MobileRegistryReauthSignOut")
        }
    }
}

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

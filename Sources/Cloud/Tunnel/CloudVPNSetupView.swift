import SwiftUI

/// One setup surface shared by Ports help and Cloud Settings.
@MainActor
struct CloudVPNSetupView: View {
    let model: CloudVPNSetupModel
    let openSystemSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label(String(localized: "cloud.vpn.setup.title", defaultValue: "Cloud VPN"), systemImage: "network")
                    .cmuxFont(.title2, weight: .semibold)
                Text(String(localized: "cloud.vpn.setup.howItWorks.body", defaultValue: "Connect Safari, Chrome, and other apps to your Cloud machines. Each machine keeps its private IP address and original ports. Only traffic to your Cloud network uses this encrypted connection. cmux terminals, Ports, and Desktop work without it."))
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(localized: "cloud.vpn.setup.address.body", defaultValue: "To open a service from another app, bind it to 0.0.0.0 or the machine’s private address. Services bound only to 127.0.0.1 remain accessible inside cmux."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(String(localized: "cloud.vpn.setup.status.title", defaultValue: "Private network status"))
                            .fontWeight(.semibold)
                        Spacer()
                        Text(model.statusTitle).accessibilityIdentifier("CloudVPNSetupStatus")
                    }
                    if let message = model.statusMessage {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("CloudVPNSetupMessage")
                    }
                    actions
                }
                if model.isSupported && model.state != .up {
                    Text(String(localized: "cloud.vpn.setup.permission.body", defaultValue: "Enabling cmux VPN adds a VPN configuration for your Cloud network. macOS may ask you to approve its network extension in System Settings."))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .cmuxFont(size: 13)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("CloudVPNSetup")
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if model.state == .up || model.state.isSettling {
                Button(model.state == .up
                    ? String(localized: "cloud.vpn.setup.disconnect", defaultValue: "Disconnect")
                    : String(localized: "cloud.vpn.setup.cancel", defaultValue: "Cancel")) {
                    Task { await model.disconnect() }
                }
                .disabled(!model.canDisconnect)
                .accessibilityIdentifier("CloudVPNDisconnectButton")
            } else {
                Button(String(localized: "cloud.vpn.setup.connect", defaultValue: "Connect Cloud VPN")) {
                    Task { await model.connect() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canConnect)
                .accessibilityIdentifier("CloudVPNConnectButton")
            }
            if model.state == .awaitingApproval {
                Button(String(localized: "cloudTree.tunnel.openSystemSettings", defaultValue: "Open System Settings"), action: openSystemSettings)
                    .accessibilityIdentifier("CloudVPNOpenSystemSettingsButton")
            }
            if model.isCheckingStatus || model.isSubmitting || model.state == .starting || model.state == .stopping {
                ProgressView().controlSize(.small)
            }
        }
    }
}

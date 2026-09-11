import AppKit
import SwiftUI

struct CloudVPNSetupPanelView: View {
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void
    let model: CloudVPNSetupModel
    var portAccessStore: CloudPortAccessStore? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                explanation
                statusCard
                actions
                if model.state != .up && model.unavailableMessage == nil { approvalSteps }
                addressHelp
                if let portAccessStore {
                    let models = portAccessStore.models.values.filter(\.prefersForwarding).sorted {
                        ($0.id.machineID, $0.id.port) < ($1.id.machineID, $1.id.port)
                    }
                    if !models.isEmpty {
                        CloudPortsTable(models: models)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: appearance.contentBackgroundColor))
        .environment(\.colorScheme, appearance.backgroundColor.isLightColor ? .light : .dark)
        .contentShape(Rectangle())
        .onTapGesture { onRequestPanelFocus() }
        .task { await model.observe() }
        .accessibilityIdentifier("CloudVPNSetupPanel")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label {
                Text(String(localized: "cloud.vpn.setup.heading", defaultValue: "Use Cloud machines from any app"))
                    .cmuxFont(.title2, weight: .semibold)
            } icon: {
                Image(systemName: "network")
                    .foregroundStyle(.blue)
            }
            Text(String(localized: "cloud.vpn.setup.subtitle", defaultValue: "Optional access to each VM's private address and original ports, such as 10.40.0.10:3000."))
                .cmuxFont(size: 13)
                .foregroundStyle(.secondary)
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(String(localized: "cloud.vpn.setup.howItWorks.title", defaultValue: "How it works"))
                .cmuxFont(size: 14, weight: .semibold)
            Text(String(localized: "cloud.vpn.setup.howItWorks.body", defaultValue: "Connect Safari, Chrome, and other apps to your Cloud machines. Each machine keeps its private IP address and original ports. Only traffic to your Cloud network uses this encrypted connection. cmux terminals, Ports, and Desktop work without it."))
                .cmuxFont(size: 13)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(localized: "cloud.vpn.setup.permission.body", defaultValue: "The VPN software is included in cmux. You do not need another app. macOS may require your password or Touch ID during approval."))
                .cmuxFont(size: 13)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(String(localized: "cloud.vpn.setup.status.title", defaultValue: "Private network status"))
                    .cmuxFont(size: 14, weight: .semibold)
                Spacer()
                statusLabel
            }
            if let message = model.errorMessage ?? model.unavailableMessage {
                Text(message)
                    .cmuxFont(size: 12)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("CloudVPNSetupError")
            } else if let banner = model.tunnelStatus.banner {
                Text(banner.text)
                    .cmuxFont(size: 12)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(String(localized: "cloud.ports.explanation", defaultValue: "Connect Cloud VPN, or choose Forward Port. Forwarding stays off until you start it. This table shows the address and lets you stop it."))
                    .cmuxFont(size: 12)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch model.state {
        case .up:
            Label(String(localized: "cloud.vpn.setup.connected", defaultValue: "Connected"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .starting, .awaitingApproval, .stopping:
            Label(String(localized: "cloud.vpn.setup.waiting", defaultValue: "Waiting"), systemImage: "clock").foregroundStyle(.orange)
        case .failed:
            Label(String(localized: "cloud.vpn.setup.failed", defaultValue: "Needs attention"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        default:
            Label(String(localized: "cloud.vpn.setup.off", defaultValue: "Off"), systemImage: "circle").foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if model.state == .up || model.state.isSettling {
                Button(model.state == .up
                    ? String(localized: "cloud.vpn.setup.disconnect", defaultValue: "Disconnect")
                    : String(localized: "cloud.vpn.setup.cancel", defaultValue: "Cancel")) {
                    Task { await model.disconnect() }
                }
                .disabled(model.isSubmitting || model.state == .stopping)
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
                Button(String(localized: "cloud.vpn.setup.openSettings", defaultValue: "Open System Settings")) {
                    SystemExtensionSettingsLink.open()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("CloudVPNOpenSystemSettingsButton")
            }
            if model.isSubmitting || model.state == .starting || model.state == .stopping {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var approvalSteps: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "cloud.vpn.setup.steps.title", defaultValue: "First-time setup"))
                .cmuxFont(size: 14, weight: .semibold)
            Text(String(localized: "cloud.vpn.setup.steps.extension", defaultValue: "1. Click Connect Cloud VPN. When macOS asks, allow the cmux network extension in System Settings."))
            Text(ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15
                ? String(localized: "cloud.vpn.setup.steps.settings", defaultValue: "Open General > Login Items & Extensions > Network Extensions, then enable cmux.")
                : String(localized: "cloud.vpn.setup.steps.settingsLegacy", defaultValue: "Open Privacy & Security and allow the cmux extension."))
                .foregroundStyle(.secondary)
            Text(String(localized: "cloud.vpn.setup.steps.configuration", defaultValue: "2. Allow cmux to add a VPN configuration named cmux Cloud. This is a separate macOS permission."))
            Text(String(localized: "cloud.vpn.setup.steps.return", defaultValue: "3. Return to this pane. The connection continues automatically after approval. Disconnect here when finished. Quitting cmux or signing out also disconnects it."))
        }
        .cmuxFont(size: 13)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var addressHelp: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "cloud.vpn.setup.address.title", defaultValue: "Private addresses"))
                .cmuxFont(size: 14, weight: .semibold)
            Text(String(localized: "cloud.vpn.setup.address.body", defaultValue: "Each machine has its own private IP. Two machines may both expose port 3000, for example 10.40.0.10:3000 and 10.40.0.11:3000. Right-click a Cloud port and choose Copy Private Address URL after connecting. These addresses are private, not public share links."))
                .cmuxFont(size: 13)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

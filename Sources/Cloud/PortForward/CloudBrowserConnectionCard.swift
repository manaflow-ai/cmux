import SwiftUI

struct CloudBrowserConnectionCard: View {
    let address: String
    let phase: CloudPortAccessModel.Phase
    let message: String?
    let setupTitle: String
    let onSetup: () -> Void
    let onRetry: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "network").font(.system(size: 28)).foregroundStyle(.secondary)
                Text(String(localized: "cloud.ports.accessTitle", defaultValue: "Connect to this Cloud port"))
                    .font(.title2.weight(.semibold))
                Text(verbatim: address).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                if let message {
                    Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text(String(localized: "cloud.vpn.setup.howItWorks.body", defaultValue: "Connect Safari, Chrome, and other apps to your Cloud machines. Each machine keeps its private IP address and original ports. Only traffic to your Cloud network uses this encrypted connection."))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "cloud.vpn.setup.steps.title", defaultValue: "First-time setup"))
                        .font(.headline)
                    Text(String(localized: "cloud.vpn.setup.steps.extension", defaultValue: "1. Click Set Up cmux VPN. When macOS asks, allow the cmux network extension in System Settings."))
                    Text(ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15
                        ? String(localized: "cloud.vpn.setup.steps.settings", defaultValue: "Open General > Login Items & Extensions > Network Extensions, then enable cmux.")
                        : String(localized: "cloud.vpn.setup.steps.settingsLegacy", defaultValue: "Open System Settings > Extensions > Network Extensions, then enable cmux."))
                    Text(String(localized: "cloud.vpn.setup.steps.configuration", defaultValue: "2. Allow cmux to add a VPN configuration named cmux Cloud."))
                    Text(String(localized: "cloud.vpn.setup.steps.return", defaultValue: "3. Return to this pane. The connection continues automatically after approval."))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                HStack {
                    Button(setupTitle, action: onSetup)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("CloudBrowserVPNSetupButton")
                    if let onRetry {
                        Button(String(localized: "browser.error.reload", defaultValue: "Reload"), action: onRetry)
                            .buttonStyle(.bordered)
                    }
                }
                if message == nil && (phase == .connecting || phase == .direct || { if case .forwarded = phase { return true }; return false }()) {
                    ProgressView(String(localized: "cloud.ports.loading", defaultValue: "Loading Cloud page…"))
                }
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("CloudBrowserConnectionCard")
    }
}

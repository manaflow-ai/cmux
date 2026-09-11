import SwiftUI

struct CloudBrowserConnectionCard: View {
    let address: String
    let phase: CloudPortAccessModel.Phase
    let message: String?
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
                Text(String(localized: "cloud.ports.explanation", defaultValue: "Connect Cloud VPN, or choose Forward Port. Forwarding stays off until you start it. This table shows the address and lets you stop it."))
                    .foregroundStyle(.secondary)
                HStack {
                    Button(String(localized: "machines.menu.setupVPN", defaultValue: "Set Up cmux VPN…"), action: onSetup)
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

import AppKit
import SwiftUI

/// One line under the Machines control bar while the explicit Cloud VPN is
/// starting, waiting for the user's extension approval, connected, or failed.
/// The approval wait carries the button that opens the System Settings pane
/// where macOS parks the extension; nothing else in the panel depends on the
/// VPN, so the tree below keeps working meanwhile.
struct MachinesTunnelBanner: View {
    let banner: CloudTunnelBanner
    let backgroundColor: NSColor
    let openSystemSettings: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            icon
            Text(banner.text)
                .cmuxFont(size: 11)
                .lineLimit(banner.kind == .connected ? 1 : 3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if banner.opensSystemSettings {
                Button(action: openSystemSettings) {
                    Text(String(localized: "cloudTree.tunnel.openSystemSettings", defaultValue: "Open System Settings"))
                        .cmuxFont(size: 11)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("CloudMachinesTunnelOpenSystemSettingsButton")
            }
        }
        .foregroundColor(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: backgroundColor))
        .help(helpText)
        .accessibilityIdentifier("CloudMachinesTunnelBanner")
    }

    @ViewBuilder
    private var icon: some View {
        switch banner.kind {
        case .starting, .stopping:
            ProgressView().controlSize(.mini)
        case .awaitingApproval:
            Image(systemName: "lock.shield").font(.system(size: 10, weight: .semibold))
        case .connected:
            Image(systemName: "network").font(.system(size: 10, weight: .semibold))
        case .failed:
            Image(systemName: "exclamationmark.triangle").font(.system(size: 10, weight: .semibold))
        }
    }

    private var tint: Color {
        switch banner.kind {
        case .awaitingApproval, .failed: return .orange.opacity(0.9)
        case .starting, .stopping, .connected: return .secondary
        }
    }

    private var helpText: String {
        String(
            localized: "cloudTree.tunnel.help",
            defaultValue: "The cmux Cloud Tunnel is a macOS network extension that gives every app on this Mac a route to your Cloud VM network. cmux itself does not need it: terminals, Ports, and Desktop use the built-in user-space tunnel."
        )
    }
}

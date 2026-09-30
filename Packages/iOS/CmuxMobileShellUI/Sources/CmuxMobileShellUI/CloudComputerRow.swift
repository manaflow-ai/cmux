#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// One Cloud machine in the Computers screen, beside the Macs.
///
/// Same idiom as a Mac row: a name, a status line, and the shared visibility
/// switch that hides the machine's workspaces on this phone. It deliberately
/// does not navigate: the Mac detail screen is about routes, pairing and
/// keep-awake, none of which a Cloud machine has; the Cloud tab is where a
/// machine is managed. Built from a value snapshot so it holds no store.
struct CloudComputerRow: View {
    let host: MobileExternalHostSummary
    let setVisible: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cloud")
                .font(.title3)
                .foregroundStyle(host.isHidden ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body)
                    .foregroundStyle(host.isHidden ? .secondary : .primary)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            ComputerVisibilityToggle(
                computerID: host.hostID,
                computerName: name,
                isVisible: !host.isHidden,
                setVisible: setVisible
            )
        }
        .accessibilityIdentifier("MobileCloudComputerRow")
    }

    private var name: String {
        if let displayName = host.displayName, !displayName.isEmpty { return displayName }
        return L10n.string("mobile.cloud.title", defaultValue: "Cloud")
    }

    private var statusLine: String {
        let phrase: String
        switch host.status {
        case .connected:
            phrase = L10n.string("mobile.deviceTree.connected", defaultValue: "Connected")
        case .reconnecting:
            phrase = L10n.string("mobile.deviceTree.reconnecting", defaultValue: "Reconnecting…")
        case .unavailable:
            phrase = L10n.string("mobile.computers.notConnected", defaultValue: "Not connected")
        }
        guard host.status == .connected else { return phrase }
        return "\(phrase) · \(L10n.terminalCountWorkspaces(host.workspaceCount))"
    }
}
#endif

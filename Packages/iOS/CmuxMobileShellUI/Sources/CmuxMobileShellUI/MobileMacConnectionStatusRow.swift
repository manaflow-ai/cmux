import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// A workspace-list row that surfaces a problem connection state (reconnecting
/// or offline) above the workspaces, so the user can tell a healthy link from a
/// recovering or dropped one. When offline and a `reconnect` action is provided,
/// it offers an explicit Reconnect button so a returning user whose auto-
/// reconnect failed is never stranded on a list with no way to act (the
/// integrated list stays the only surface — no separate picker screen).
struct MobileMacConnectionStatusRow: View {
    let host: String
    let status: MobileMacConnectionStatus
    /// Manual reconnect for the offline (`.unavailable`) state. `nil` in previews
    /// and where reconnect is not applicable.
    var reconnect: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.symbolName)
                .font(.body.weight(.semibold))
                .foregroundStyle(status.tintColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(host.isEmpty ? status.description : host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if status == .unavailable, let reconnect {
                Button(action: reconnect) {
                    Text(L10n.string("mobile.workspace.reconnect", defaultValue: "Reconnect"))
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("MobileMacReconnectButton")
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobileMacConnectionStatus")
    }
}

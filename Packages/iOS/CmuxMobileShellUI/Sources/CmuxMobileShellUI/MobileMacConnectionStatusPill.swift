import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// A compact connection-status pill overlaid on the terminal view, shown only
/// when the connection is down and reconnect attempts have stopped. A healthy
/// connection shows no chrome, and reconnecting surfaces as the quieter
/// title-bar spinner (`WorkspaceToolbarTitleView`) instead of a pill.
struct MobileMacConnectionStatusPill: View {
    let host: String
    let status: MobileMacConnectionStatus
    var reconnect: (() -> Void)?

    @ViewBuilder
    var body: some View {
        if status == .unavailable {
            if let reconnect {
                Button(action: reconnect) {
                    pill
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(
                    L10n.string("mobile.workspace.reconnect", defaultValue: "Reconnect")
                )
                .accessibilityIdentifier("MobileTerminalMacConnectionStatus")
            } else {
                pill
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityIdentifier("MobileTerminalMacConnectionStatus")
            }
        }
    }

    private var pill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(status.tintColor)
                .frame(width: 8, height: 8)

            Text(status.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.78), in: Capsule())
    }

    private var accessibilityLabel: String {
        host.isEmpty ? status.label : "\(host), \(status.label)"
    }
}

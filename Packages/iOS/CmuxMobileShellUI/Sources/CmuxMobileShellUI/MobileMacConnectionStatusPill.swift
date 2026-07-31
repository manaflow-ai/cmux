import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// A compact connection-status pill overlaid on the terminal view, shown only
/// for problem states (reconnecting / offline). A healthy connection shows no
/// chrome.
struct MobileMacConnectionStatusPill: View {
    let host: String
    let status: MobileMacConnectionStatus
    var reconnect: (() -> Void)?

    @ViewBuilder
    var body: some View {
        // Only surface the pill for problem states (reconnecting / offline).
        // A healthy connection shows no chrome.
        if status != .connected {
            if let reconnect, status == .unavailable {
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

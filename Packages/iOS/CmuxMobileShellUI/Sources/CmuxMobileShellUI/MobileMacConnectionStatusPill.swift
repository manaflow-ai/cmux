import CmuxMobileShellModel
import SwiftUI

/// A compact connection-status pill overlaid on the terminal view, shown only
/// for problem states (reconnecting / offline). A healthy connection shows no
/// chrome.
struct MobileMacConnectionStatusPill: View {
    let host: String
    let status: MobileMacConnectionStatus

    var body: some View {
        // Only surface the pill for problem states (reconnecting / offline).
        // A healthy connection shows no chrome.
        if status != .connected {
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
            .accessibilityElement(children: .combine)
            .accessibilityLabel(host.isEmpty ? status.label : "\(host), \(status.label)")
            .accessibilityIdentifier("MobileTerminalMacConnectionStatus")
        }
    }
}

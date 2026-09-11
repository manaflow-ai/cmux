#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct TerminalSendStatusPill: View {
    let status: MobileTerminalSendStatus

    var body: some View {
        if status == .sending || status == .failed {
            HStack(spacing: 7) {
                if status == .sending {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.red)
                }

                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("MobileTerminalSendStatus")
        }
    }

    private var title: String {
        switch status {
        case .idle:
            return ""
        case .sending:
            return L10n.string("mobile.terminal.sending", defaultValue: "Sending")
        case .sent:
            return ""
        case .failed:
            return L10n.string("mobile.terminal.sendFailed.short", defaultValue: "Send failed")
        }
    }
}
#endif

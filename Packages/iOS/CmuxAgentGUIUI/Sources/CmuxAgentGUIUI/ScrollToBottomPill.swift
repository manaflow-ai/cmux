#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct ScrollToBottomPill: View {
    let unreadCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                if unreadCount > 0 {
                    Text(AgentGUIL10n.unreadValue(unreadCount))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .mobileGlassPill()
        .accessibilityLabel(AgentGUIL10n.string(
            "agent.transcript.pill.label",
            defaultValue: "Jump to latest message"
        ))
        .accessibilityValue(unreadCount > 0 ? AgentGUIL10n.unreadValue(unreadCount) : "")
    }
}
#endif

#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct ScrollToBottomPill: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let unreadCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                if unreadCount > 0 {
                    Text(AgentGUIL10n.unreadValue(unreadCount))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .opacity : .numericText())
                        .animation(
                            reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.22),
                            value: unreadCount
                        )
                }
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
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

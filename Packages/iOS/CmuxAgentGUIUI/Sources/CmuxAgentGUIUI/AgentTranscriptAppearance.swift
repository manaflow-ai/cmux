#if os(iOS)
import CmuxAgentChatUI
import CmuxAgentGUIProjection
import SwiftUI

struct AgentTranscriptAppearance {
    let chatTheme: ChatTheme
    let colorScheme: ColorScheme

    init(theme: AgentGUITheme, density: TranscriptDensity) {
        chatTheme = ChatTheme(
            accent: Color(theme.accent),
            incomingBubbleFill: .clear,
            terminalCardText: Color(theme.foreground),
            outgoingBubbleFill: Color(theme.inputBackground),
            terminalCardFill: Color(theme.raisedBackground),
            hairline: Color(theme.border),
            horizontalMargin: 12,
            groupSpacing: density == .compact ? 8 : 12,
            intraGroupSpacing: 4,
            bubbleMaxWidthFraction: 0.94
        )
        colorScheme = theme.prefersDarkAppearance ? .dark : .light
    }
}
#endif

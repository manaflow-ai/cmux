import CmuxAgentConversationUI
import SwiftUI

/// Hosts ``AgentChatView`` as pane tab content for an ``AgentChatPanel``.
///
/// The chat view owns its model as `@State`; tying the view identity to the
/// panel id keeps that model stable across re-renders while letting each
/// panel read its own transcript.
struct AgentChatPanelView: View {
    let panel: AgentChatPanel
    let isFocused: Bool
    let onRequestPanelFocus: () -> Void

    var body: some View {
        AgentChatView(source: panel.conversationSource)
            .id(panel.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.textBackgroundColor))
            .simultaneousGesture(TapGesture().onEnded {
                if !isFocused {
                    onRequestPanelFocus()
                }
            })
    }
}

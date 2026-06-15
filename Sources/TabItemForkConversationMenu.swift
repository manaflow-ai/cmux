import AppKit
import SwiftUI

extension TabItemView {
    @ViewBuilder
    func forkConversationContextMenuSection(canFork: Bool) -> some View {
        if canFork {
            Divider()

            Button(String(localized: "contextMenu.forkConversation", defaultValue: "Fork Conversation")) {
                forkFocusedAgentConversation(destination: AgentConversationForkDefaultSettings.current())
            }

            Menu(String(localized: "contextMenu.forkConversationTo", defaultValue: "Fork Conversation To")) {
                ForEach(AgentConversationForkDestination.allCases) { destination in
                    Button(destination.settingsTitle) {
                        forkFocusedAgentConversation(destination: destination)
                    }
                }
            }
        }
    }

    private func forkFocusedAgentConversation(destination: AgentConversationForkDestination) {
        guard tab.forkFocusedAgentConversation(destination: destination) else {
            NSSound.beep()
            return
        }
    }
}

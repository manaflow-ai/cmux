import CmuxAgentChat
import SwiftUI

#Preview("Chat — full fixture") {
    let (messages, descriptor) = ChatFixtureConversation().make()
    let source = FixtureChatEventSource(backlog: messages, replyToSends: true)
    let store = ChatConversationStore(descriptor: descriptor, source: source)
    NavigationStack {
        ChatScreen(store: store, onOpenTerminal: {})
    }
    .preferredColorScheme(.dark)
}

#Preview("Pending bubble states") {
    let actions = ChatRowActions()
    VStack(spacing: 12) {
        ChatPendingBubbleView(
            pending: ChatPendingOutbound(
                id: "p1",
                text: "Run the suite again",
                                createdAt: Date(),
                delivery: .queued
            ),
            actions: actions
        )
        ChatPendingBubbleView(
            pending: ChatPendingOutbound(
                id: "p2",
                text: "Now push the branch",
                attachments: [ChatOutboundAttachment(data: Data([0x89]), format: .png)],
                createdAt: Date(),
                delivery: .sending
            ),
            actions: actions
        )
        ChatPendingBubbleView(
            pending: ChatPendingOutbound(
                id: "p3",
                text: "And open a PR",
                                createdAt: Date(),
                delivery: .delivered
            ),
            actions: actions
        )
        ChatPendingBubbleView(
            pending: ChatPendingOutbound(
                id: "p4",
                text: "Also fix the flaky integration job",
                attachments: [
                    ChatOutboundAttachment(data: Data([0x89]), format: .png),
                    ChatOutboundAttachment(data: Data([0x89]), format: .jpeg),
                ],
                createdAt: Date(),
                delivery: .failed("Connection lost")
            ),
            actions: actions
        )
    }
    .padding()
    .preferredColorScheme(.dark)
}

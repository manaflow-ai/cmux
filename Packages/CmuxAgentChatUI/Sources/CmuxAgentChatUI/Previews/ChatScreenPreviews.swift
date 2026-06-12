import CmuxAgentChat
import SwiftUI

#Preview("Chat — full fixture") {
    let (messages, descriptor) = ChatFixtureConversation.make()
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
                attachmentCount: 0,
                createdAt: Date(),
                delivery: .queued
            ),
            actions: actions
        )
        ChatPendingBubbleView(
            pending: ChatPendingOutbound(
                id: "p2",
                text: "Now push the branch",
                attachmentCount: 1,
                createdAt: Date(),
                delivery: .sending
            ),
            actions: actions
        )
        ChatPendingBubbleView(
            pending: ChatPendingOutbound(
                id: "p3",
                text: "And open a PR",
                attachmentCount: 0,
                createdAt: Date(),
                delivery: .delivered
            ),
            actions: actions
        )
        ChatPendingBubbleView(
            pending: ChatPendingOutbound(
                id: "p4",
                text: "Also fix the flaky integration job",
                attachmentCount: 2,
                createdAt: Date(),
                delivery: .failed("Connection lost")
            ),
            actions: actions
        )
    }
    .padding()
    .preferredColorScheme(.dark)
}

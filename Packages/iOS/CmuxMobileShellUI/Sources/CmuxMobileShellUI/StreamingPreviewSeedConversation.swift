#if canImport(UIKit) && DEBUG
import CmuxAgentChat
import CmuxAgentChatUI
import Foundation

struct StreamingPreviewSeedConversation {
    let environment: [String: String]

    func make() -> ([ChatMessage], ChatSessionDescriptor) {
        if let repeatCount = uiTestFixtureRepeatCount(), repeatCount > 1 {
            let (messages, descriptor) = ChatFixtureConversation().make()
            return (repeatedMessages(messages, repeatCount: repeatCount), descriptor)
        }

        let descriptor = ChatSessionDescriptor(
            id: "streaming-preview",
            agentKind: .claude,
            title: "Streaming preview"
        )
        let prompt = ChatMessage(
            id: "preview-user-0",
            seq: 0,
            role: .user,
            timestamp: Date(),
            kind: .prose(ChatProse(text: "Reply with three short sentences about the color blue."))
        )
        return ([prompt], descriptor)
    }

    private func uiTestFixtureRepeatCount() -> Int? {
        let rawValue = environment["CMUX_UITEST_AGENT_CHAT_FIXTURE_REPEAT_COUNT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rawValue.flatMap(Int.init)
    }

    private func repeatedMessages(_ messages: [ChatMessage], repeatCount: Int) -> [ChatMessage] {
        var repeatedMessages: [ChatMessage] = []
        repeatedMessages.reserveCapacity(messages.count * repeatCount)
        for repeatIndex in 0..<repeatCount {
            for message in messages {
                repeatedMessages.append(
                    ChatMessage(
                        id: "\(message.id)-repeat-\(repeatIndex)",
                        seq: repeatedMessages.count,
                        role: message.role,
                        timestamp: message.timestamp.addingTimeInterval(TimeInterval(repeatIndex * messages.count)),
                        kind: message.kind
                    )
                )
            }
        }
        return repeatedMessages
    }
}
#endif

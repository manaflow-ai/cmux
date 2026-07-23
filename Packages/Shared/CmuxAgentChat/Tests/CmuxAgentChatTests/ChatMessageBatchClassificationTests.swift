import Foundation
import Testing
@testable import CmuxAgentChat

@Suite("Chat message batch classification")
struct ChatMessageBatchClassificationTests {
    @Test("Only committed agent prose settles the streaming preview")
    func detectsAgentProse() {
        let userProse = message(role: .user, timestamp: 1, kind: .prose(ChatProse(text: "prompt")))
        let agentThought = message(role: .agent, timestamp: 2, kind: .thought(ChatThought(text: "thinking")))
        let agentProse = message(role: .agent, timestamp: 3, kind: .prose(ChatProse(text: "answer")))

        #expect(![userProse, agentThought].containsAgentProse)
        #expect([userProse, agentThought, agentProse].containsAgentProse)
    }

    private func message(
        role: ChatRole,
        timestamp: TimeInterval,
        kind: ChatMessageKind
    ) -> ChatMessage {
        ChatMessage(
            id: "\(timestamp)",
            seq: Int(timestamp),
            role: role,
            timestamp: date(timestamp),
            kind: kind
        )
    }

    private func date(_ timestamp: TimeInterval) -> Date {
        Date(timeIntervalSince1970: timestamp)
    }
}

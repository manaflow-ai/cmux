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

    @Test("Completed assistant turn uses the latest settled agent timestamp")
    func findsCompletedTurnTimestamp() {
        let earlier = message(role: .agent, timestamp: 2, kind: .thought(ChatThought(text: "thinking")))
        let later = message(role: .agent, timestamp: 4, kind: .prose(ChatProse(text: "answer")))

        #expect([later, earlier].completedAssistantTurnTimestamp == date(4))
        #expect([ChatMessage]().completedAssistantTurnTimestamp == nil)
    }

    @Test("Unfinished agent work prevents turn completion")
    func rejectsUnfinishedAgentWork() {
        let prose = message(role: .agent, timestamp: 2, kind: .prose(ChatProse(text: "answer")))
        let tool = message(
            role: .agent,
            timestamp: 3,
            kind: .toolUse(ChatToolUse(toolName: "Read", summary: "Read file"))
        )

        #expect([prose, tool].completedAssistantTurnTimestamp == nil)
    }

    @Test("Thought-only and unsupported batches do not complete a turn")
    func requiresFinalAgentProse() {
        let thought = message(
            role: .agent,
            timestamp: 2,
            kind: .thought(ChatThought(text: "thinking"))
        )
        let unsupported = message(
            role: .agent,
            timestamp: 3,
            kind: .unsupported(ChatUnsupportedPayload(rawType: "future_reasoning"))
        )

        #expect([thought].completedAssistantTurnTimestamp == nil)
        #expect([unsupported].completedAssistantTurnTimestamp == nil)
        #expect([thought, unsupported].completedAssistantTurnTimestamp == nil)
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

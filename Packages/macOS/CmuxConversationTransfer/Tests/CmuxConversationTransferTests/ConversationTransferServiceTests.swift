import Testing
@testable import CmuxConversationTransfer

struct ConversationTransferServiceTests {
    @Test
    func roleLabeledMessageIncludesUserAndAssistantDialogue() throws {
        let message = try ConversationTransferService().message(
            for: [
                ConversationTurn(id: 0, role: .user, text: "Inspect the parser."),
                ConversationTurn(id: 1, role: .assistant, text: "The parser drops one field."),
                ConversationTurn(id: 2, role: .tool, text: "private tool output"),
            ],
            sourceDisplayName: "Codex"
        )

        #expect(message.contains("Codex"))
        #expect(message.contains("User:\nInspect the parser."))
        #expect(message.contains("Assistant:\nThe parser drops one field."))
        #expect(!message.contains("private tool output"))
    }

    @Test
    func compactionKeepsOpeningRequestAndLatestReply() throws {
        let turns = [
            ConversationTurn(id: 0, role: .user, text: "OPENING " + String(repeating: "request ", count: 80)),
            ConversationTurn(id: 1, role: .assistant, text: String(repeating: "old response ", count: 80)),
            ConversationTurn(id: 2, role: .user, text: String(repeating: "follow-up ", count: 80)),
            ConversationTurn(id: 3, role: .assistant, text: "LATEST answer"),
        ]
        let policy = ConversationTransferPolicy(
            maximumCharacters: 1_024,
            initialUserCharacterLimit: 300
        )

        let message = try ConversationTransferService(policy: policy).message(
            for: turns,
            sourceDisplayName: "Codex"
        )

        #expect(message.contains("OPENING"))
        #expect(message.contains("LATEST answer"))
        #expect(message.count <= policy.maximumCharacters)
        #expect(message.contains("Conversation compacted"))
    }

    @Test
    func formatterRemovesTerminalControlCharacters() throws {
        let message = try ConversationTransferService().message(
            for: [
                ConversationTurn(id: 0, role: .user, text: "safe\u{1B}]0;renamed\u{7}\u{0}\nnext"),
            ],
            sourceDisplayName: "Codex\u{1B}"
        )

        #expect(message.contains("safe]0;renamed\nnext"))
        #expect(!message.unicodeScalars.contains { scalar in
            scalar.value == 0 || scalar.value == 7 || scalar.value == 27
        })
    }

    @Test
    func emptyOrExcludedConversationFails() {
        #expect(throws: ConversationTransferError.emptyConversation) {
            try ConversationTransferService().message(
                for: [ConversationTurn(id: 0, role: .tool, text: "tool only")],
                sourceDisplayName: "Codex"
            )
        }
    }
}

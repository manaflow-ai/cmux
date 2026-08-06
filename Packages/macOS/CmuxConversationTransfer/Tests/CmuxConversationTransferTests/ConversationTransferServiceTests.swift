import Foundation
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
            maximumBytes: 1_024,
            initialUserByteLimit: 300
        )

        let message = try ConversationTransferService(policy: policy).message(
            for: turns,
            sourceDisplayName: "Codex"
        )

        #expect(message.contains("OPENING"))
        #expect(message.contains("LATEST answer"))
        #expect(message.utf8.count <= policy.maximumBytes)
        #expect(message.contains("Conversation compacted"))
    }

    @Test
    func singleLongOpeningRequestUsesAvailableConversationBudget() {
        let policy = ConversationTransferPolicy(
            maximumBytes: 2_048,
            initialUserByteLimit: 256
        )
        let compaction = TailPreservingConversationCompactor().compact(
            [
                ConversationTurn(
                    id: 0,
                    role: .user,
                    text: String(repeating: "request ", count: 1_000)
                ),
            ],
            policy: policy,
            formattedByteCount: { $0.text.utf8.count + 8 }
        )

        let retained = compaction.turns.first?.text.utf8.count ?? 0
        #expect(retained > policy.initialUserByteLimit)
        #expect(retained <= policy.maximumBytes - 512)
        #expect(compaction.shortenedTurnCount == 1)
        #expect(compaction.omittedTurnCount == 0)
    }

    @Test
    func combiningMarksCannotExceedUTF8ByteBudget() throws {
        let pathologicalOpening = "OPENING e" + String(repeating: "\u{0301}", count: 4_000)
        let policy = ConversationTransferPolicy(
            maximumBytes: 1_024,
            initialUserByteLimit: 384
        )

        let message = try ConversationTransferService(policy: policy).message(
            for: [
                ConversationTurn(id: 0, role: .user, text: pathologicalOpening),
                ConversationTurn(id: 1, role: .assistant, text: "LATEST answer"),
            ],
            sourceDisplayName: "Codex"
        )

        #expect(message.contains("OPENING"))
        #expect(message.contains("LATEST answer"))
        #expect(message.utf8.count <= policy.maximumBytes)
        #expect(String(data: Data(message.utf8), encoding: .utf8) == message)
    }

    @Test
    func localizedRoleFramingPreservesLatestTurn() throws {
        let policy = ConversationTransferPolicy(maximumBytes: 24_000)
        let turns = (0..<1_000).map { index in
            ConversationTurn(
                id: index,
                role: .assistant,
                text: index == 999 ? "LATEST-LOCALIZED-MARKER" : "xxxxxx"
            )
        }

        let message = try ConversationTransferService(
            formatter: JapaneseRoleLabelFormatter(),
            policy: policy
        ).message(
            for: turns,
            sourceDisplayName: "Claude"
        )

        #expect(message.contains("LATEST-LOCALIZED-MARKER"))
        #expect(message.utf8.count <= policy.maximumBytes)
    }

    @Test
    func formatterRemovesTerminalControlCharacters() throws {
        let message = try ConversationTransferService().message(
            for: [
                ConversationTurn(
                    id: 0,
                    role: .user,
                    text: "safe\u{1B}]0;renamed\u{7}\u{0}\u{009B}31mred\u{009D}52;c;payload\u{009C}\nnext"
                ),
            ],
            sourceDisplayName: "Codex\u{1B}"
        )

        #expect(message.contains("safe]0;renamed31mred52;c;payload\nnext"))
        #expect(!message.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (value < 32 && value != 9 && value != 10)
                || (127...159).contains(value)
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

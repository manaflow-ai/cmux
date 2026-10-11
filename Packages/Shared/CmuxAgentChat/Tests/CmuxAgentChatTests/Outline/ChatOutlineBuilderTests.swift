import CmuxAgentChat
import Foundation
import Testing

@Suite("Chat outline builder")
struct ChatOutlineBuilderTests {
    private func message(
        _ id: String,
        seq: Int,
        role: ChatRole,
        _ kind: ChatMessageKind
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            seq: seq,
            role: role,
            timestamp: Date(timeIntervalSince1970: Double(seq)),
            kind: kind
        )
    }

    @Test("one entry per prompt with the first line of the first prose reply")
    func summarizesPromptsAndReplies() {
        let messages = [
            message("p1", seq: 10, role: .user, .prose(ChatProse(text: "Investigate the login flow\nwith a focused test"))),
            message("t1", seq: 11, role: .agent, .thought(ChatThought(text: "thinking"))),
            message("a1", seq: 12, role: .agent, .prose(ChatProse(text: "\nThe login flow   retries twice.\n\nIt then fails.\nMore detail."))),
            message("a2", seq: 13, role: .agent, .prose(ChatProse(text: "A later reply is not the preview."))),
            message("p2", seq: 20, role: .user, .prose(ChatProse(text: "Document the result"))),
        ]

        let entries = ChatOutlineBuilder().entries(from: messages)

        #expect(entries.map(\.id) == ["p1", "p2"])
        #expect(entries.map(\.seq) == [10, 20])
        #expect(entries.map(\.title) == ["Investigate the login flow", "Document the result"])
        #expect(entries.map(\.replyPreview) == ["The login flow retries twice. It then fails.", nil])
    }

    @Test("a prompt line with an attachment is one entry titled by its prose")
    func attachmentAndProseOnOneLineAreOneEntry() {
        let attachment = ChatAttachment(media: .image, displayName: "screenshot.png")
        let messages = [
            message("p1-0", seq: 5, role: .user, .attachment(attachment)),
            message("p1-1", seq: 5, role: .user, .prose(ChatProse(text: "What is wrong in this screenshot?"))),
            message("p2-0", seq: 9, role: .user, .attachment(attachment)),
        ]

        let entries = ChatOutlineBuilder().entries(from: messages)

        #expect(entries.map(\.id) == ["p1-0", "p2-0"])
        #expect(entries.map(\.title) == ["What is wrong in this screenshot?", "screenshot.png"])
    }

    @Test("interruption markers, shell-mode echoes and compaction summaries are not prompts")
    func skipsNonPromptUserLines() {
        let messages = [
            message("p1", seq: 1, role: .user, .prose(ChatProse(text: "Run the tests"))),
            message("x1", seq: 2, role: .user, .prose(ChatProse(text: "[Request interrupted by user]"))),
            message("x2", seq: 3, role: .user, .prose(ChatProse(text: "<bash-input>ls</bash-input>"))),
            message("x3", seq: 4, role: .user, .prose(ChatProse(text: "This session is being continued from a previous conversation that ran out of context."))),
            message("p2", seq: 5, role: .user, .prose(ChatProse(text: "Try again"))),
        ]

        #expect(ChatOutlineBuilder().entries(from: messages).map(\.id) == ["p1", "p2"])
    }

    @Test("titles are clipped and whitespace-collapsed")
    func clipsLongTitles() {
        let long = String(repeating: "word  ", count: 60)
        let entries = ChatOutlineBuilder().entries(from: [
            message("p1", seq: 1, role: .user, .prose(ChatProse(text: long))),
        ])

        #expect(entries.first?.title.count == ChatOutlineEntry.titleLimit)
        #expect(entries.first?.title.contains("  ") == false)
        #expect(entries.first?.isTitleClipped == true)
    }
}

@Suite("Chat outline accumulator")
struct ChatOutlineAccumulatorTests {
    private func prose(_ id: String, seq: Int, role: ChatRole, _ text: String) -> ChatMessage {
        ChatMessage(id: id, seq: seq, role: role, timestamp: Date(timeIntervalSince1970: 0), kind: .prose(ChatProse(text: text)))
    }

    @Test("live batches extend the outline and fill the pending reply preview")
    func liveBatchesExtendOutline() {
        var accumulator = ChatOutlineAccumulator()
        accumulator.ingest([prose("p1", seq: 0, role: .user, "first")])
        #expect(accumulator.entries.map(\.replyPreview) == [nil])

        accumulator.ingest([prose("a1", seq: 1, role: .agent, "done")])
        accumulator.ingest([prose("p2", seq: 2, role: .user, "second")])

        #expect(accumulator.entries.map(\.title) == ["first", "second"])
        #expect(accumulator.entries.map(\.replyPreview) == ["done", nil])
    }

    @Test("overlapping batches do not duplicate prompts")
    func overlappingBatchesAreIdempotent() {
        var accumulator = ChatOutlineAccumulator()
        let batch = [prose("p1", seq: 0, role: .user, "first"), prose("p2", seq: 4, role: .user, "second")]
        accumulator.ingest(batch)
        accumulator.ingest(batch)

        #expect(accumulator.entries.map(\.id) == ["p1", "p2"])
    }

    @Test("the cap keeps the newest prompts and reports the truncated head")
    func capKeepsNewest() {
        var accumulator = ChatOutlineAccumulator(maxEntries: 2)
        accumulator.ingest((0..<5).map { prose("p\($0)", seq: $0, role: .user, "prompt \($0)") })

        #expect(accumulator.entries.map(\.id) == ["p3", "p4"])
        #expect(accumulator.isHeadTruncated)

        accumulator.reset()
        #expect(accumulator.entries.isEmpty)
        #expect(!accumulator.isHeadTruncated)
        accumulator.ingest([prose("q0", seq: 0, role: .user, "after reset")])
        #expect(accumulator.entries.map(\.id) == ["q0"])
    }
}

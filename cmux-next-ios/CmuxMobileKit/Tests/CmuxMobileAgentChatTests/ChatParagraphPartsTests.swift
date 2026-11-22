#if os(iOS)
@testable import CmuxMobileAgentChat
import CmuxMobileMarkdown
import Foundation
import Testing

/// A long paragraph is several transcript rows that read as the one paragraph (#47189: a 240-line
/// log as one row reset the transcript list under the reader). Shared by every transcript list.
@MainActor
@Suite struct ChatParagraphPartsTests {
    static let log = MockStressContent.giantPrompt(1)
    static let environment = ChatNativeEnvironment(width: 350, category: .large, wrapCode: false)

    static func height(_ text: String) throws -> CGFloat {
        try #require(ChatNativeLayout.make(.block(messageID: "m", block: MarkdownBlock(id: 0, kind: .paragraph(text))), id: "m#0",
                                           expanded: false, environment: environment)).height
    }

    @Test func aShortParagraphAndOtherBlocksStayOneRow() {
        #expect(ChatParagraphParts.split(MarkdownBlock(id: 0, kind: .paragraph("one\ntwo"))).count == 1)
        let code = MarkdownBlock(id: 1, kind: .code(language: nil, code: Self.log, isClosed: true))
        #expect(ChatParagraphParts.split(code).count == 1, "only paragraphs split")
    }

    @Test func aLongParagraphSplitsIntoPartsThatRejoinToIt() throws {
        let block = try #require(MarkdownDocument(parsing: Self.log).blocks.first)
        guard case .paragraph(let text) = block.kind else { Issue.record("the log is one paragraph"); return }
        let parts = ChatParagraphParts.split(block)
        #expect(parts.count >= 10, "\(parts.count) parts for 240 lines")
        let rejoined = parts.map { part -> String in
            guard case .paragraph(let piece) = part.kind else { return "?" }
            return piece
        }.joined(separator: "\n")
        #expect(rejoined == text, "the parts are the paragraph's lines, in order")
        #expect(parts.allSatisfy { $0.id == block.id })
    }

    /// Drawn one under the other with the paragraph's line spacing, the parts are as tall as the
    /// paragraph: rows that come in as parts move nothing the reader sees (0.5 pt).
    @Test func thePartsAreAsTallAsTheParagraph() throws {
        let block = try #require(MarkdownDocument(parsing: Self.log).blocks.first)
        guard case .paragraph(let text) = block.kind else { return }
        let parts = ChatParagraphParts.split(block)
        var total: CGFloat = 0
        for (number, part) in parts.enumerated() {
            guard case .paragraph(let piece) = part.kind else { continue }
            total += try Self.height(piece) + (number > 0 ? ChatParagraphParts.lineGap : 0)
        }
        let whole = try Self.height(text)
        print("CMUX_PARAGRAPH_PARTS \(parts.count) parts: whole \(whole) pt, parts \(total) pt")
        #expect(abs(whole - total) <= 0.5 * CGFloat(parts.count), "parts \(total) pt, whole \(whole) pt")
    }

    /// The agent chat's builder: a finished answer's long paragraph is parts (the first keeps the
    /// block's row id, the next `<id>.<n>` 5 pt below); the streaming tail stays one row.
    @Test func theBuilderSplitsAFinishedAnswerButNotTheStreamingTail() {
        let store = AgentChatStore(source: SmoothChatTests.Silent())
        store.nextFrame = nil
        store.apply(.batch([
            .userMessage(text: "log", promptId: "p0", turnId: "t0", attachments: [], at: SmoothChatTests.at),
            .turnStarted(turnId: "t0", at: SmoothChatTests.at),
            .update(.agentMessageChunk(text: Self.log, messageId: "m0")),
        ]))
        let builder = ChatTranscriptBuilder(diffs: ChatDiffCache())
        func blockRows() -> [ChatRow] {
            builder.build(turns: store.turns, pendingPermission: nil, askOpen: false, permissionBarHidden: false, foldsWork: false)
                .flatMap(\.rows).filter { if case .block = $0.kind { true } else { false } }
        }
        #expect(blockRows().count == 1, "streaming, the paragraph is one row")
        store.apply(.turnResult(turnId: "t0", status: .completed, errorText: nil, at: SmoothChatTests.at))
        let rows = blockRows()
        #expect(rows.count >= 10, "finished, it is \(rows.count) rows")
        #expect(rows.first?.id == "m-m0#0", "the first part keeps the block's row id")
        #expect(rows.dropFirst().allSatisfy { $0.id.hasPrefix("m-m0#0.") && $0.gap == ChatParagraphParts.lineGap })
        #expect(Set(rows.map(\.id)).count == rows.count, "ids are unique")
    }
}
#endif

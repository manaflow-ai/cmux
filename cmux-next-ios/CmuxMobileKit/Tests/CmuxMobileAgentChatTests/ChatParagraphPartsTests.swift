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
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let rejoined = ChatParagraphParts.partLines(block).map { lines[$0].joined(separator: "\n") }.joined(separator: "\n")
        // No marks to carry in the log: the drawn parts are its lines exactly.
        #expect(parts.map { part -> String in if case .paragraph(let piece) = part.kind { piece } else { "?" } }.joined(separator: "\n") == text)
        #expect(rejoined == text, "the parts are the paragraph's lines, in order")
        #expect(parts.allSatisfy { $0.id == block.id })
    }

    /// A paragraph whose marks never close within a window (a code span opened on its first
    /// line, a stray star, ANSI `[31m` brackets) still splits: each part closes what is open at its
    /// end and opens it again at the next part's start, so every part draws as the paragraph did.
    @Test func aParagraphWithOpenMarksStillSplits() throws {
        var lines = ["`start of a code span that never closes"]
        lines += (1..<100).map { "\u{1B}[31merror\u{1B}[0m line \($0) of the log *note" }
        let block = MarkdownBlock(id: 0, kind: .paragraph(lines.joined(separator: "\n")))
        let parts = ChatParagraphParts.split(block)
        #expect(parts.count >= 2, "\(parts.count) parts for 100 lines")
        for (number, part) in parts.enumerated() {
            guard case .paragraph(let text) = part.kind else { continue }
            let marks = ChatParagraphParts.Marks().after(text.split(separator: "\n", omittingEmptySubsequences: false)[...])
            #expect(marks.isEmpty || number == parts.count - 1, "part \(number) closes its marks: \(marks)")
            #expect(text.split(separator: "\n").count <= 2 * ChatParagraphParts.maxLines, "part \(number) is at most twice the window")
        }
        // Without the added marks (the paragraph's own lines per part), the parts rejoin to it.
        let ranges = ChatParagraphParts.partLines(block)
        #expect(ranges.count == parts.count)
        #expect(ranges.map { lines[$0].joined(separator: "\n") }.joined(separator: "\n") == lines.joined(separator: "\n"))
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

    /// Find in Chat in a 100-line paragraph: a match in its last part resolves to that part's row
    /// (not the first part, screens above), with its place in that part; one in the first part to
    /// the first.
    @Test(arguments: [false, true])
    func aFindMatchResolvesToThePartThatHoldsIt(forced: Bool) throws {
        // `forced`: a code span opened on the first line never closes, so every part is a forced
        // split that closes and reopens it (the match's offsets count the paragraph's own text).
        let first = forced ? "`open span on line 0" : "line 0 of the log, attempt=0"
        let paragraph = ([first] + (1..<100).map { "line \($0) of the log, attempt=\($0 * 3)" }).joined(separator: "\n")
        let store = AgentChatStore(source: SmoothChatTests.Silent())
        store.nextFrame = nil
        store.apply(.batch([
            .userMessage(text: "log", promptId: "p0", turnId: "t0", attachments: [], at: SmoothChatTests.at),
            .turnStarted(turnId: "t0", at: SmoothChatTests.at),
            .update(.agentMessageChunk(text: paragraph, messageId: "m0")),
            .turnResult(turnId: "t0", status: .completed, errorText: nil, at: SmoothChatTests.at),
        ]))
        let list = ChatTranscriptList(store: store, surface: AgentChatSurface())
        list.foldsWork = false
        list.collectionView.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        list.boundsMayHaveChanged()
        list.collectionView.layoutIfNeeded()
        let parts = list.layout.items.map(\.id).filter { $0.hasPrefix("m-m0#0") }
        #expect(parts.count >= 2, "the paragraph split: \(parts)")
        let ranges = ChatParagraphParts.partLines(MarkdownBlock(id: 0, kind: .paragraph(paragraph)))
        func partHolding(_ line: Int) -> String {
            parts[ranges.firstIndex { $0.contains(line) } ?? 0]
        }
        let blocks = AgentChatFind.blocks(of: store.turns)
        for line in [3, 50, 99] {
            let match = try #require(AgentChatFind.matches(of: "line \(line) of", in: blocks).first)
            let target = list.findTarget(block: match.block, position: match.position)
            #expect(target.id == partHolding(line), "line \(line) resolves to the part that holds it, got \(target.id)")
        }
    }

}
#endif

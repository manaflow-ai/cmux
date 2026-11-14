import CmuxMobileMarkdown
import Foundation
import Testing
@testable import CmuxMobileAgentChat
#if os(iOS)
import UIKit

/// The work one streamed token costs the transcript is the rows it changed, not the rows of the
/// turn it grows. The energy bench's stream-chat case (one long answer, 40 turns above it) read
/// 8 to 25% of a core in the simulator: every token made, compared and estimated every block of
/// the answer again (about 150 of them by its end) and offered every row of the chat to the
/// warm-up. Counted here per 1,000 tokens of that answer.
@MainActor
@Suite struct StreamingWorkTests {
    static let tokens = 1_000
    static let tokenSize = 6

    /// 40 finished turns, then a running turn whose answer holds all of the bench's long answer
    /// but its last 1,000 tokens; the reader scrolled up, as the bench leaves it.
    static func streamingChat() -> (store: AgentChatStore, list: ChatTranscriptList, rest: [String]) {
        let answer = Array(MockStressContent.streamedAnswer)
        let split = answer.count - tokens * tokenSize
        let rest = stride(from: split, to: answer.count, by: tokenSize).map { String(answer[$0..<min($0 + tokenSize, answer.count)]) }
        let store = AgentChatStore(source: SmoothChatTests.Silent())
        store.nextFrame = nil
        store.apply(.batch((0..<40).flatMap { SmoothChatTests.turn($0) } + [
            .userMessage(text: "stream", promptId: "p40", turnId: "t40", attachments: [], at: SmoothChatTests.at),
            .turnStarted(turnId: "t40", at: SmoothChatTests.at),
            .update(.agentMessageChunk(text: String(answer[..<split]), messageId: "m40")),
        ]))
        let surface = AgentChatSurface()
        let list = ChatTranscriptList(store: store, surface: surface)
        list.collectionView.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        list.boundsMayHaveChanged()
        list.collectionView.layoutIfNeeded()
        surface.following = false
        list.collectionView.contentOffset = .zero
        return (store, list, rest)
    }

    /// What a list built from scratch shows for `store`: the streamed list must match it.
    static func freshRows(_ store: AgentChatStore) -> (ids: [String], rows: [ChatRow?]) {
        let fresh = ChatTranscriptList(store: store, surface: AgentChatSurface())
        fresh.collectionView.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        fresh.boundsMayHaveChanged()
        let ids = fresh.layout.items.map(\.id)
        return (ids, ids.map { fresh.row($0) })
    }

    @Test func aTokenWeighsTheRowsItChangedNotItsTurn() {
        let (store, list, rest) = Self.streamingChat()
        #expect(rest.count == Self.tokens)
        let answerBlocks = list.layout.items.filter { $0.id.hasPrefix("m-m40#") }.count
        #expect(answerBlocks > 80, "the answer has \(answerBlocks) blocks")
        let made = list.builder.rowsMade, weighed = list.rowsWeighed, offered = list.warmUpOffers
        for (index, token) in rest.enumerated() {
            store.apply(.update(.agentMessageChunk(text: token, messageId: "m40")))
            list.reload()
            if index % 250 == 249 {
                // Nothing lost or stale: the streamed list shows what a list built now shows.
                let fresh = Self.freshRows(store)
                let ids = list.layout.items.map(\.id)
                #expect(ids == fresh.ids, "after \(index + 1) tokens")
                #expect(ids.map { list.row($0) } == fresh.rows, "after \(index + 1) tokens")
            }
        }
        let rowsMade = list.builder.rowsMade - made
        let rowsWeighed = list.rowsWeighed - weighed
        let warmUpOffers = list.warmUpOffers - offered
        // The prompt, the working line and the one or two blocks the token changed.
        #expect(rowsMade <= 5 * Self.tokens, "rows made per \(Self.tokens) tokens: \(rowsMade)")
        #expect(rowsWeighed <= 5 * Self.tokens, "rows weighed per \(Self.tokens) tokens: \(rowsWeighed)")
        // The rows the token changed, not every row of the chat on every token.
        #expect(warmUpOffers <= 5 * Self.tokens, "rows offered to the warm-up per \(Self.tokens) tokens: \(warmUpOffers)")
        #expect(store.turns.last?.lastAnswerMarkdown == MockStressContent.streamedAnswer)
    }
}
#endif

/// `MarkdownStreamParse.unchangedDisplayed` never claims a block that changed: the rows it lets
/// the transcript keep are the rows a full build makes.
@Suite struct MarkdownStreamUnchangedTests {
    @Test func theUnchangedBlocksAreTheOnesShownBefore() {
        let answer = (0..<6).map { n in
            "## Part \(n)\n\nSome *text* with `code` and a [link](https://x.y) and **bold\n\n```swift\nfunc f\(n)() {\n    return\n}\n```\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n- a\n- b\n  continued\n\n> quote \(n)\n\n---"
        }.joined(separator: "\n\n")
        var parse = MarkdownStreamParse()
        var shown = ""
        var index = answer.startIndex
        var step = 1
        var kept = 0
        while index < answer.endIndex {
            let before = parse.displayed
            let end = answer.index(index, offsetBy: step % 9 + 1, limitedBy: answer.endIndex) ?? answer.endIndex
            shown += answer[index..<end]
            index = end
            step += 1
            parse.update(shown, isStreaming: true)
            #expect(parse.unchangedDisplayed <= min(before.count, parse.displayed.count))
            #expect(Array(parse.displayed.prefix(parse.unchangedDisplayed)) == Array(before.prefix(parse.unchangedDisplayed)),
                    "after \(shown.count) characters")
            kept += parse.unchangedDisplayed
        }
        #expect(kept > 0)
        // The turn ends: the tail's hidden markers show again.
        let before = parse.displayed
        parse.update(answer, isStreaming: false)
        #expect(Array(parse.displayed.prefix(parse.unchangedDisplayed)) == Array(before.prefix(parse.unchangedDisplayed)))
        #expect(parse.displayed == MarkdownDocument(parsing: answer).blocks)
        // A rewritten message keeps nothing.
        parse.update("other text", isStreaming: false)
        #expect(parse.unchangedDisplayed == 0)
    }
}

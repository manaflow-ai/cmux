#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import CmuxMobileAgentChat

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
        // Each new row once (a block the answer started), not every row on every token.
        #expect(warmUpOffers <= Self.tokens, "rows offered to the warm-up per \(Self.tokens) tokens: \(warmUpOffers)")
        #expect(store.turns.last?.lastAnswerMarkdown == MockStressContent.streamedAnswer)
    }
}
#endif

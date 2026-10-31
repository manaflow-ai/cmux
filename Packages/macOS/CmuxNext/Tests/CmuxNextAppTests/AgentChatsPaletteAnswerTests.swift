@testable import CmuxNextAgentLanes
@testable import CmuxNextAgentPane
import CmuxNextPalette
import Foundation
import Testing

/// Review of #28090, finding 1: the palette's chats page runs its spinner until the query's stream
/// ends (`PalettePageSpec.queryResults`), so the stream ends after acpmux's first answer for the
/// query, an empty one too (the page then shows its empty state, not a spinner forever).
@MainActor @Suite struct AgentChatsPaletteAnswerTests {
    // A stream with no end hangs at its second read: the limit fails it at once, not at the lane's timeout.
    @Test(.timeLimit(.minutes(1))) func aQueryStreamEndsAfterAcpmuxAnswersIt() async throws {
        let windows = AcpmuxChatWindows()
        var sent: [[String: any Sendable]] = []
        windows.connected { _, params in sent.append(params) }
        let stream = AgentChatsPalettePage.answers("nothing matches", windows: windows, open: { _ in })
        let generation = try #require(sent.last?["gen"] as? UInt64)
        windows.apply(.init(window: AgentChatsPalettePage.window, generation: generation, revision: 1, full: true, keys: [], rows: []))
        var answers = stream.makeAsyncIterator()
        let first = await answers.next()
        #expect(first?.isEmpty == true, "an empty answer shows the empty state")
        // acpmux sends the window again: an ended stream gets nothing more (with no end, this second
        // read would get the second answer and the spinner would never stop).
        windows.apply(.init(window: AgentChatsPalettePage.window, generation: generation, revision: 2, full: true, keys: [], rows: []))
        let second = await answers.next()
        #expect(second == nil, "one answer, then the stream ends")
    }

    /// No regression (review of #28090): acpmux ranks every chat and says how many matched; when
    /// more match than the page holds, the page says so in a last row that runs nothing.
    @Test func morePastThePageIsShownAsANoticeRow() async throws {
        let windows = AcpmuxChatWindows()
        var sent: [[String: any Sendable]] = []
        windows.connected { _, params in sent.append(params) }
        let stream = AgentChatsPalettePage.answers("codex", windows: windows, open: { _ in })
        let params = try #require(sent.last)
        #expect(params["untitled"] as? String == AgentChatsPaletteStrings.untitled, "acpmux finds an untitled chat by the page's word")
        let generation = try #require(params["gen"] as? UInt64)
        let row: [String: Any] = ["key": "codex:1", "sessionId": "1", "harness": "codex", "title": "Port the parser", "updatedMs": 1_000]
        let message: [String: Any] = ["window": AgentChatsPalettePage.window, "gen": NSNumber(value: generation), "revision": 1,
                                      "full": true, "keys": ["codex:1"], "rows": [row], "hasMore": true, "total": 250]
        windows.apply(try #require(AcpmuxChatWindows.Update(params: message)))
        var answers: [[PaletteItem]] = []
        for await answer in stream { answers.append(answer) }
        let shown = try #require(answers.first)
        #expect(shown.map(\.id) == ["chat:codex:1", "agentChats.more"], "the chat, then the notice: \(shown.map(\.id))")
        #expect(shown.last?.isEnabled == false)
        #expect(shown.last?.title.contains("250") == true)
    }

    /// No regression (lead, #28090): the palette ranked a chat the person chose before above an
    /// equal match. The page sends its choice history of chats with the query; acpmux ranks with it.
    @Test func aQuerySendsThePersonsChoiceHistory() throws {
        let windows = AcpmuxChatWindows()
        var sent: [[String: any Sendable]] = []
        windows.connected { _, params in sent.append(params) }
        let used = FrecencyStore.Entry(score: 2, lastUsed: Date(timeIntervalSinceReferenceDate: 1_000))
        let store = FrecencyStore(entries: ["chat:codex:1": used, "action.other": used])
        let history = store.rankerHistory(keyPrefix: "chat:", query: "fix", now: Date(timeIntervalSinceReferenceDate: 2_000))
        _ = AgentChatsPalettePage.answers("fix", windows: windows, history: history, open: { _ in })
        let text = try #require(sent.last?["history"] as? String)
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let entries = try #require((decoded["frecency"] as? [String: Any])?["entries"] as? [String: Any])
        #expect(Array(entries.keys) == ["chat:codex:1"], "only the chats' history goes: \(entries.keys)")
        #expect(decoded["now"] as? Double == 2_000)
    }

    /// The empty query lists the newest page and says how many more chats there are (R-L5).
    @Test func theEmptyQuerySaysHowManyMoreChatsThereAre() async throws {
        let windows = AcpmuxChatWindows()
        var sent: [[String: any Sendable]] = []
        windows.connected { _, params in sent.append(params) }
        let stream = AgentChatsPalettePage.answers("", windows: windows, open: { _ in })
        let params = try #require(sent.last)
        #expect(params["count"] as? Bool == true, "the page asks acpmux to count every chat")
        let generation = try #require(params["gen"] as? UInt64)
        let row: [String: Any] = ["key": "codex:1", "sessionId": "1", "harness": "codex", "title": "Port the parser", "updatedMs": 1_000]
        let message: [String: Any] = ["window": AgentChatsPalettePage.window, "gen": NSNumber(value: generation), "revision": 1,
                                      "full": true, "keys": ["codex:1"], "rows": [row], "hasMore": true, "total": 3_000]
        windows.apply(try #require(AcpmuxChatWindows.Update(params: message)))
        var answers: [[PaletteItem]] = []
        for await answer in stream { answers.append(answer) }
        let shown = try #require(answers.first)
        #expect(shown.map(\.id) == ["chat:codex:1", "agentChats.more"], "\(shown.map(\.id))")
        #expect(shown.last?.title.contains("2,999") == true || shown.last?.title.contains("2999") == true,
                "the row names the 2,999 chats it leaves out: \(shown.last?.title ?? "")")
    }
}

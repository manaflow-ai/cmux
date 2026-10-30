@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextPalette
import Foundation
import Testing

/// Review of #28090, finding 1: the palette's chats page runs its spinner until the query's stream
/// ends (`PalettePageSpec.queryResults`), so the stream ends after acpmux's first answer for the
/// query, an empty one too (the page then shows its empty state, not a spinner forever).
@MainActor @Suite struct AgentChatsPaletteAnswerTests {
    @Test func aQueryStreamEndsAfterAcpmuxAnswersIt() async throws {
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
}

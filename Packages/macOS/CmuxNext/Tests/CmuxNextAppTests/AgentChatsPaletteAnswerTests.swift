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
        windows.connected { (_: String, params: [String: any Sendable]) in sent.append(params) }
        let stream = AgentChatsPalettePage.answers("nothing matches", windows: windows, open: { _, _ in })
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

    /// Review 2 of #28090: after a reconnect every window is asked again, and until acpmux's full
    /// answer comes the rows are the old connection's. An unchanged query is not answered then.
    @Test func aWindowIsNotAnsweredAgainUntilTheNewConnectionAnswers() throws {
        let windows = AcpmuxChatWindows()
        var sent: [[String: any Sendable]] = []
        windows.connected { (_: String, params: [String: any Sendable]) in sent.append(params) }
        let spec = AcpmuxChatWindows.Spec(window: AgentChatsPalettePage.window, limit: 10, query: "zebra")
        windows.open(spec)
        let generation = try #require(sent.last?["gen"] as? UInt64)
        windows.apply(.init(window: spec.window, generation: generation, revision: 1, full: true, keys: [], rows: []))
        #expect(windows.isAnswered(spec))
        windows.connected { (_: String, params: [String: any Sendable]) in sent.append(params) }
        #expect(sent.count == 2, "the new connection asks for the window again")
        #expect(!windows.isAnswered(spec), "the old connection's rows do not answer the new connection's request")
        windows.apply(.init(window: spec.window, generation: generation, revision: 1, full: true, keys: [], rows: []))
        #expect(windows.isAnswered(spec))
        // Review 3 M2: a reconnect, then acpmux refuses the request (busy): still not answered.
        windows.connected { (_: String, params: [String: any Sendable]) in sent.append(params) }
        windows.requestFailed(spec.window)
        #expect(!windows.isAnswered(spec), "a refused request after a reconnect does not answer with the old rows")
    }

    /// Review 3 M1: without a connection to acpmux, or when it refuses the query, the page's answer ends at once
    /// with no rows (the palette does not wait for chats that will not come).
    @Test(.timeLimit(.minutes(1))) func aQueryEndsAtOnceWithoutAcpmux() async throws {
        let windows = AcpmuxChatWindows()
        var none: [[PaletteItem]] = []
        for await answer in AgentChatsPalettePage.answers("zebra", windows: windows, open: { _, _ in }) { none.append(answer) }
        #expect(none.allSatisfy { $0.isEmpty }, "no connection: no rows")
        var sent: [[String: any Sendable]] = []
        windows.connected { (_: String, params: [String: any Sendable]) in sent.append(params) }
        let stream = AgentChatsPalettePage.answers("quokka", windows: windows, open: { _, _ in })
        windows.requestFailed(AgentChatsPalettePage.window)
        var refused: [[PaletteItem]] = []
        for await answer in stream { refused.append(answer) }
        #expect(refused.allSatisfy { $0.isEmpty }, "refused: no rows")
    }

    /// Review 4 note 3: acpmux refuses an older spec of the window after the current one went out: the current
    /// query's answer is not ended, and its rows still count when they come.
    @Test(.timeLimit(.minutes(1))) func anOlderRefusalDoesNotEndTheCurrentQuery() async throws {
        let windows = AcpmuxChatWindows()
        var sent: [[String: any Sendable]] = []
        windows.connected { (_: String, params: [String: any Sendable]) in sent.append(params) }
        _ = AgentChatsPalettePage.answers("old", windows: windows, open: { _, _ in })
        let older = try #require(sent.last?["gen"] as? UInt64)
        let stream = AgentChatsPalettePage.answers("new", windows: windows, open: { _, _ in })
        let current = try #require(sent.last?["gen"] as? UInt64)
        #expect(current > older)
        windows.requestFailed(AgentChatsPalettePage.window, generation: older)
        let row: [String: Any] = ["key": "codex:1", "sessionId": "1", "harness": "codex", "title": "New parser", "updatedMs": 1_000]
        let message: [String: Any] = ["window": AgentChatsPalettePage.window, "gen": NSNumber(value: current), "revision": 1,
                                      "full": true, "keys": ["codex:1"], "rows": [row]]
        windows.apply(try #require(AcpmuxChatWindows.Update(params: message)))
        var answers: [[PaletteItem]] = []
        for await answer in stream { answers.append(answer) }
        #expect(answers.first?.map(\.id) == ["chat:codex:1"], "\(answers)")
    }

    /// Review 4 note 2: acpmux answers `ready: false` (its index has not started): the query ends at once with no
    /// rows, as a refusal does, so the palette never waits on a timer.
    @Test(.timeLimit(.minutes(1))) func aNotReadyAnswerEndsTheQueryAtOnce() async throws {
        let windows = AcpmuxChatWindows()
        var sent: [[String: any Sendable]] = []
        windows.connected { (_: String, params: [String: any Sendable]) in sent.append(params) }
        let stream = AgentChatsPalettePage.answers("zebra", windows: windows, open: { _, _ in })
        let generation = try #require(sent.last?["gen"] as? UInt64)
        windows.requestNotReady(AgentChatsPalettePage.window, generation: generation)
        var answers: [[PaletteItem]] = []
        for await answer in stream { answers.append(answer) }
        #expect(answers.allSatisfy { $0.isEmpty }, "\(answers)")
    }

    /// Review 4 note 6: the chats page asks again when acpmux can answer: a connection comes, or an index that
    /// was not ready fills the window.
    @Test func theSourceChangesWhenAcpmuxCanAnswer() throws {
        let windows = AcpmuxChatWindows()
        final class Owner {}
        let owner = Owner()
        var changes = 0
        windows.followAvailability(owner) { changes += 1 }
        var sent: [[String: any Sendable]] = []
        windows.connected { (_: String, params: [String: any Sendable]) in sent.append(params) }
        #expect(changes == 1, "a connection came")
        windows.open(.init(window: AgentChatsPalettePage.window, limit: 10, query: "zebra"))
        let generation = try #require(sent.last?["gen"] as? UInt64)
        windows.requestNotReady(AgentChatsPalettePage.window, generation: generation)
        windows.apply(.init(window: AgentChatsPalettePage.window, generation: generation, revision: 1, full: true, keys: [], rows: []))
        #expect(changes == 2, "the index that was not ready answered")
    }

    /// Review 5 note 2: Search's more row counts the chats past acpmux's page from the answer itself, so it stays
    /// right after the chats page's window closed (the person went back from the pushed Agent Chats page).
    @Test(.timeLimit(.minutes(1))) func theMoreRowKeepsItsCountAfterTheWindowCloses() async throws {
        let windows = AcpmuxChatWindows()
        var sent: [[String: any Sendable]] = []
        windows.connected { (_: String, params: [String: any Sendable]) in sent.append(params) }
        let page = AgentChatsPalettePage(windows: windows, history: { _ in nil }, open: { _, _ in }).page()
        let results = try #require(page.queryResults)
        let stream = results("idle")
        for _ in 0..<500 where !sent.contains(where: { $0["query"] as? String == "idle" }) { await Task.yield() }
        let generation = try #require(sent.last?["gen"] as? UInt64)
        let keys = (0..<200).map { "codex:\($0)" }
        let rows: [[String: Any]] = (0..<200).map { (index: Int) -> [String: Any] in
            ["key": keys[index], "sessionId": "\(index)", "harness": "codex", "title": "Idle \(index)", "updatedMs": 1_000]
        }
        let message: [String: Any] = ["window": AgentChatsPalettePage.window, "gen": NSNumber(value: generation), "revision": 1,
                                      "full": true, "keys": keys, "rows": rows, "hasMore": true, "total": 250]
        windows.apply(try #require(AcpmuxChatWindows.Update(params: message)))
        for await _ in stream {}
        page.onCancel?()
        let moreRow = try #require(page.moreRow)
        let more = moreRow(5, "idle")
        #expect(more.title.contains("55"), "5 cut plus 50 past the page: \(more.title)")
    }

    /// Review 5 note 4: ChatsFeed reads acpmux's `ready: false` answer as not ready (not a refusal), a `stale` answer
    /// as neither, and keeps each window request's spec generation until its answer.
    @Test func chatsFeedReadsNotReadyAndKeepsTheGeneration() throws {
        let notReady = ChatsFeed.Message(line: Data(#"{"jsonrpc":"2.0","id":5,"result":{"window":"palette.chats","ready":false}}"#.utf8))
        #expect(notReady == .answered(id: 5, failed: false, notReady: true))
        let stale = ChatsFeed.Message(line: Data(#"{"jsonrpc":"2.0","id":6,"result":{"window":"palette.chats","gen":1,"stale":true,"ready":false}}"#.utf8))
        #expect(stale == .answered(id: 6, failed: false, notReady: false))
        let refused = ChatsFeed.Message(line: Data(#"{"jsonrpc":"2.0","id":7,"error":{"code":-32602,"message":"bad"}}"#.utf8))
        #expect(refused == .answered(id: 7, failed: true, notReady: false))
        let request = ChatsFeed.windowRequest(method: "_acpmux/chats_window", params: ["window": "palette.chats", "gen": UInt64(4)])
        #expect(request?.window == "palette.chats" && request?.generation == 4, "\(String(describing: request))")
        #expect(ChatsFeed.windowRequest(method: "_acpmux/chats_window_close", params: ["window": "palette.chats"]) == nil)
    }

    /// No regression (review of #28090): acpmux ranks every chat and says how many matched; when
    /// more match than the page holds, the page says so in a last row that runs nothing.
    @Test func morePastThePageIsShownAsANoticeRow() async throws {
        let windows = AcpmuxChatWindows()
        var sent: [[String: any Sendable]] = []
        windows.connected { (_: String, params: [String: any Sendable]) in sent.append(params) }
        let stream = AgentChatsPalettePage.answers("codex", windows: windows, open: { _, _ in })
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
        windows.connected { (_: String, params: [String: any Sendable]) in sent.append(params) }
        let used = FrecencyStore.Entry(score: 2, lastUsed: Date(timeIntervalSinceReferenceDate: 1_000))
        let store = FrecencyStore(entries: ["chat:codex:1": used, "action.other": used])
        let history = store.rankerHistory(keyPrefix: "chat:", query: "fix", now: Date(timeIntervalSinceReferenceDate: 2_000))
        _ = AgentChatsPalettePage.answers("fix", windows: windows, history: history, open: { _, _ in })
        let text = try #require(sent.last?["history"] as? String)
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let entries = try #require((decoded["frecency"] as? [String: Any])?["entries"] as? [String: Any])
        #expect(Array(entries.keys) == ["chat:codex:1"], "only the chats' history goes: \(entries.keys)")
        #expect(decoded["now"] as? Double == 2_000)
    }

    /// Dealbreakers D4: a query finds a chat by what was said in it, not only its title. The page asks
    /// acpmux for it (`content`); a row found that way shows the message's snippet with the words
    /// emphasized, and opens the chat scrolled to that message.
    @Test func aChatFoundByWhatWasSaidShowsTheSnippetAndOpensAtTheMessage() async throws {
        let windows = AcpmuxChatWindows()
        var sent: [[String: any Sendable]] = []
        windows.connected { (_: String, params: [String: any Sendable]) in sent.append(params) }
        var opened: [(String, String?)] = []
        let stream = AgentChatsPalettePage.answers("zephyrine", windows: windows, open: { opened.append(($0, $1)) })
        let params = try #require(sent.last)
        #expect(params["content"] as? Bool == true, "the page asks acpmux to search what was said")
        let generation = try #require(params["gen"] as? UInt64)
        let said: [String: Any] = ["turn": 3, "role": "answer", "snippet": "…fails on zephyrine columns", "highlights": [9, 10, 11, 12, 13, 14, 15, 16, 17],
                                   "matches": 1]
        let row: [String: Any] = ["key": "codex:1", "sessionId": "1", "harness": "codex", "title": "Port the parser", "cwd": "/tmp/p",
                                  "updatedMs": 1_000, "match": said]
        let message: [String: Any] = ["window": AgentChatsPalettePage.window, "gen": NSNumber(value: generation), "revision": 1,
                                      "full": true, "keys": ["codex:1"], "rows": [row], "hasMore": false, "total": 1]
        windows.apply(try #require(AcpmuxChatWindows.Update(params: message)))
        var answers: [[PaletteItem]] = []
        for await answer in stream { answers.append(answer) }
        let item = try #require(answers.first?.first)
        #expect(item.title == "Port the parser")
        #expect(item.subtitle == "…fails on zephyrine columns", "the snippet stands where the folder was")
        #expect(item.subtitleHighlights == [9, 10, 11, 12, 13, 14, 15, 16, 17])
        guard case .perform(let run) = item.primary.effect else { Issue.record("the row opens the chat"); return }
        run()
        #expect(opened.first?.0 == "codex:1")
        #expect(opened.first?.1 == "said:answer:zephyrine", "it opens at the answer that holds the word")
    }

    /// Review of #38431, F2: a query typed while acpmux still reads chats for the first time keeps its
    /// stream open (each answer shows), so a chat whose words are read later still appears; the stream ends
    /// with the answer that is no longer `filling`.
    @Test(.timeLimit(.minutes(1))) func aQueryDuringTheFirstReadStaysOpenUntilItEnds() async throws {
        let windows = AcpmuxChatWindows()
        var sent: [[String: any Sendable]] = []
        windows.connected { (_: String, params: [String: any Sendable]) in sent.append(params) }
        let stream = AgentChatsPalettePage.answers("zephyrine", windows: windows, open: { _, _ in })
        let generation = try #require(sent.last?["gen"] as? UInt64)
        func update(_ revision: UInt64, keys: [String], filling: Bool) throws -> AcpmuxChatWindows.Update {
            let rows: [[String: Any]] = keys.map { ["key": $0, "sessionId": $0, "harness": "codex", "title": $0, "updatedMs": 1_000] }
            var message: [String: Any] = ["window": AgentChatsPalettePage.window, "gen": NSNumber(value: generation), "revision": NSNumber(value: revision),
                                          "full": true, "keys": keys, "rows": rows, "hasMore": false, "total": keys.count]
            if filling { message["filling"] = true }
            return try #require(AcpmuxChatWindows.Update(params: message))
        }
        // The page buffers only the newest answer: each is taken before the next update comes.
        var answers = stream.makeAsyncIterator()
        windows.apply(try update(1, keys: [], filling: true))
        #expect(await answers.next()?.map(\.id) == [], "the empty first answer shows")
        windows.apply(try update(2, keys: ["codex:1"], filling: false))
        #expect(await answers.next()?.map(\.id) == ["chat:codex:1"], "then the chat read later")
        #expect(await answers.next() == nil, "the answer that is no longer filling ends the stream")
    }

    /// The empty query lists the newest page and says how many more chats there are (R-L5).
    @Test func theEmptyQuerySaysHowManyMoreChatsThereAre() async throws {
        let windows = AcpmuxChatWindows()
        var sent: [[String: any Sendable]] = []
        windows.connected { (_: String, params: [String: any Sendable]) in sent.append(params) }
        let stream = AgentChatsPalettePage.answers("", windows: windows, open: { _, _ in })
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

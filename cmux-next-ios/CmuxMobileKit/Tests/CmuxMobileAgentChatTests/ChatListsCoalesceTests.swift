@testable import CmuxMobileAgentChat
import Foundation
import Observation
import Testing

/// Resumes waiting frames when a test says a frame went by.
@MainActor final class TestFrames {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var count: Int { waiting.count }

    func next() async { await withCheckedContinuation { waiting.append($0) } }

    /// Waits for someone to wait on the frame, then lets it go by.
    func fire() async {
        for _ in 0..<1000 where waiting.isEmpty { await Task.yield() }
        let resumed = waiting
        waiting = []
        for continuation in resumed { continuation.resume() }
        for _ in 0..<5 { await Task.yield() }
    }
}

/// The subagent transcript and the Subagents list (L7): live changes coalesce to one apply per
/// frame, and the screens build their rows and order once per change, not once per redraw.
@MainActor
@Suite struct SubagentListsCoalesceTests {
    final class Silent: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m")
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    static let at = Date(timeIntervalSince1970: 1_700_000_000)

    func store(_ ids: [String]) -> AgentChatStore {
        let store = AgentChatStore(source: Silent())
        store.nextFrame = nil
        for id in ids { store.apply(.subagent(AgentSubagentChange(id: id, name: id, task: "task \(id)", state: .running, at: Self.at))) }
        return store
    }

    static func tool(_ n: Int) -> ACPSessionUpdate {
        .toolCall(ACPToolCall(id: "c\(n)", title: "Read f\(n).swift", kind: .read, status: .completed))
    }

    @Test func aChangeToOneSubagentBuildsNoRowsForAnother() throws {
        let store = store(["a", "b"])
        store.apply(.subagentUpdate(subagentID: "b", .agentMessageChunk(text: "B's answer", messageId: "mb")))
        let memo = SubagentRowsMemo()
        _ = memo.rows(for: try #require(store.subagent("b")))
        #expect(memo.builds == 1)
        for n in 0..<100 {
            store.apply(.subagentUpdate(subagentID: "a", Self.tool(n)))
            _ = memo.rows(for: try #require(store.subagent("b")))
        }
        #expect(memo.builds == 1, "100 changes to A rebuilt B's rows \(memo.builds - 1) times")
    }

    @Test func aBurstOfSubagentChunksIsOneApplyPerFrame() async throws {
        let store = store(["b"])
        let frames = TestFrames()
        store.nextFrame = { await frames.next() }
        let memo = SubagentRowsMemo()
        _ = memo.rows(for: try #require(store.subagent("b")))
        for n in 0..<100 {
            store.receive(.subagentUpdate(subagentID: "b", .agentMessageChunk(text: "w\(n) ", messageId: "m")))
        }
        await Task.yield()
        #expect(store.subagent("b")?.items.isEmpty == true, "the chunks wait for the frame")
        await frames.fire()
        #expect(store.chunkFlushes == 1, "100 chunks, \(store.chunkFlushes) applies")
        let rows = memo.rows(for: try #require(store.subagent("b"))).rows
        #expect(memo.builds == 2)
        guard case .message(_, let text)? = rows.last else { Issue.record("no message row"); return }
        #expect(text.hasPrefix("w0 w1 ") && text.hasSuffix("w98 w99 "))
    }

    /// SUB-11: 1000 tokens in one frame are one coalesced apply and one row build.
    @Test func aThousandTokenBurstIsOneApplyAndOneRowBuild() async throws {
        let store = store(["b"])
        let frames = TestFrames()
        store.nextFrame = { await frames.next() }
        let memo = SubagentRowsMemo()
        _ = memo.rows(for: try #require(store.subagent("b")))
        for n in 0..<1000 {
            store.receive(.subagentUpdate(subagentID: "b", .agentMessageChunk(text: "w\(n) ", messageId: "m")))
        }
        await Task.yield()
        #expect(store.subagent("b")?.items.isEmpty == true, "the tokens wait for the frame")
        await frames.fire()
        #expect(store.chunkFlushes == 1, "1000 tokens, \(store.chunkFlushes) applies")
        let rows = memo.rows(for: try #require(store.subagent("b"))).rows
        #expect(memo.builds == 2, "1000 tokens built rows \(memo.builds - 1) times")
        guard case .message(_, let text)? = rows.last else { Issue.record("no message row"); return }
        #expect(text.hasPrefix("w0 w1 ") && text.hasSuffix("w998 w999 "))
    }

    /// SUB-11: 1000 mixed items (tool runs and answers) landing between two redraws build the
    /// rows once, and every item is in them.
    @Test func aThousandItemBurstBuildsRowsOnce() throws {
        let store = store(["b"])
        let memo = SubagentRowsMemo()
        _ = memo.rows(for: try #require(store.subagent("b")))
        for n in 0..<1000 {
            store.apply(.subagentUpdate(subagentID: "b", n % 2 == 0 ? Self.tool(n) : .agentMessageChunk(text: "a\(n)", messageId: "m\(n)")))
        }
        let agent = try #require(store.subagent("b"))
        #expect(agent.items.count == 1000)
        _ = memo.rows(for: agent)
        _ = memo.rows(for: agent)
        #expect(memo.builds == 2, "1000 items between redraws built rows \(memo.builds - 1) times")
    }

    @Test func otherSubagentRecordsKeepTheirOrderAfterWaitingChunks() async throws {
        let store = store(["b"])
        let frames = TestFrames()
        store.nextFrame = { await frames.next() }
        store.receive(.subagentUpdate(subagentID: "b", .agentMessageChunk(text: "before", messageId: "m1")))
        store.receive(.subagentUpdate(subagentID: "b", Self.tool(1)))
        store.receive(.subagentUpdate(subagentID: "b", .agentMessageChunk(text: "after", messageId: "m2")))
        await frames.fire()
        let items = try #require(store.subagent("b")).items
        #expect(items.count == 3)
        if case .message(_, let text) = items[0] { #expect(text == "before") } else { Issue.record("first is not the message") }
        if case .tool(let call) = items[1] { #expect(call.id == "c1") } else { Issue.record("second is not the tool") }
        if case .message(_, let text) = items[2] { #expect(text == "after") } else { Issue.record("third is not the message") }
    }

    @Test func rowsAreBuiltOncePerContentChange() throws {
        let store = store(["b"])
        let memo = SubagentRowsMemo()
        var previous = memo.rows(for: try #require(store.subagent("b"))).rows
        for n in 0..<200 {
            store.apply(.subagentUpdate(subagentID: "b", n % 4 == 0 ? .agentMessageChunk(text: "m\(n)", messageId: "m\(n)") : Self.tool(n)))
            // Redraws between applies read the rows again.
            _ = memo.rows(for: try #require(store.subagent("b")))
            let rows = memo.rows(for: try #require(store.subagent("b"))).rows
            // Rows an append did not touch keep their identity and value.
            let kept = rows.dropLast()
            for (old, new) in zip(previous.dropLast(), kept) {
                #expect(old.id == new.id && old == new)
            }
            previous = rows
        }
        #expect(memo.builds == 201, "200 applies built rows \(memo.builds) times")
    }

    static func call(_ n: Int, status: ACPToolCall.Status = .completed) -> TurnItem {
        .tool(ACPToolCall(id: "c\(n)", title: "Read f\(n).swift", kind: .read, status: status))
    }

    /// A 2000-item transcript: answers, thoughts and runs of tool calls.
    static func long(_ count: Int = 2000) -> AgentSubagent {
        var agent = AgentSubagent(id: "b", parent: nil, name: "b", task: "t", startedAt: at)
        agent.items = (0..<count).map { n in
            switch n % 5 {
            case 0: .message(id: "m\(n)", markdown: "Answer \(n)")
            case 1: .thought(id: "t\(n)", text: "Thinking \(n)")
            default: call(n)
            }
        }
        return agent
    }

    @Test func anAppendMakesTheRowsItChangedNotTheTranscripts() {
        var agent = Self.long()
        let memo = SubagentRowsMemo()
        _ = memo.rows(for: agent)
        var made = memo.rowsMade
        var previous = memo.rows(for: agent).rows
        for n in 0..<300 {
            switch n % 3 {
            case 0: agent.items.append(.message(id: "new\(n)", markdown: "New \(n)"))
            case 1:
                // A token on the last answer.
                if case .message(let id, let markdown) = agent.items[agent.items.count - 1] {
                    agent.items[agent.items.count - 1] = .message(id: id, markdown: markdown + " more")
                }
            default: agent.items.append(Self.call(10_000 + n))
            }
            let rows = memo.rows(for: agent).rows
            let cost = memo.rowsMade - made
            made = memo.rowsMade
            #expect(cost <= 2, "change \(n) to a \(agent.items.count)-item transcript made \(cost) rows")
            #expect(rows == agent.asTurn.rows, "the rows match a full build after change \(n)")
            // Rows the change did not touch keep their identity and value.
            for (old, new) in zip(previous.dropLast(2), rows) { #expect(old.id == new.id && old == new) }
            previous = rows
        }
    }

    @Test func rowsMatchAFullBuildThroughRandomChanges() {
        var generator = SystemRandomNumberGenerator()
        var agent = Self.long(200)
        let memo = SubagentRowsMemo()
        for step in 0..<400 {
            let index = Int.random(in: 0..<max(agent.items.count, 1), using: &generator)
            switch Int.random(in: 0..<6, using: &generator) {
            case 0: agent.items.append(Self.call(50_000 + step, status: .inProgress))
            case 1 where !agent.items.isEmpty:
                // A call in the middle finishes.
                if case .tool(var call) = agent.items[index] { call.status = .failed; agent.items[index] = .tool(call) }
            case 2 where !agent.items.isEmpty: agent.items.remove(at: index)
            case 3: agent.items.insert(.message(id: "i\(step)", markdown: "Inserted"), at: min(index, agent.items.count))
            case 4: agent.items.append(.thought(id: "nt\(step)", text: "More"))
            default: agent.state = step % 2 == 0 ? .running : .completed
            }
            #expect(memo.rows(for: agent).rows == agent.asTurn.rows, "step \(step)")
        }
    }

    /// SUB-8's guard (SB ≤ 0.5 pt): a finished subagent whose tall row is measured while the
    /// reader is near the end does not move the reader's row.
    @Test func aFinishedTranscriptMeasuringATallRowNearTheEndMovesNothing() {
        var follow = SubagentFollow()
        // The reader scrolls to 40 pt from the end of a finished transcript and comes to rest.
        _ = follow.changed(atEnd: true, grew: false, scrolling: true, running: false)
        _ = follow.changed(atEnd: true, grew: false, scrolling: false, running: false)
        // A log row near the reader is measured: its estimate grows by 14,000 pt.
        var offset = 9_000.0
        var height = 10_000.0
        for growth in [2_000.0, 6_000.0, 6_000.0] {
            let anchor = follow.sizeChangeAnchor(running: false)
            let next = SubagentFollow.offset(offset, anchor: anchor, old: height, new: height + growth)
            let shift = abs(next - offset)
            #expect(shift <= 0.5, "a measured row moved the reader's row \(shift) pt (anchor \(anchor))")
            // Mutating calls stay outside #expect (its expansion takes the value immutably).
            let scrolls = follow.changed(atEnd: false, grew: true, scrolling: false, running: false)
            #expect(!scrolls, "a finished transcript never scrolls to its end")
            offset = next
            height += growth
        }
    }

    /// The same reader on a running subagent follows its end: growth keeps the end in place.
    @Test func aRunningTranscriptAtTheEndKeepsTheEndInPlace() {
        var follow = SubagentFollow()
        _ = follow.changed(atEnd: true, grew: false, scrolling: false, running: true)
        #expect(follow.sizeChangeAnchor(running: true) == .bottom)
        let offset = SubagentFollow.offset(9_000, anchor: .bottom, old: 10_000, new: 10_120)
        #expect(offset == 9_120, "the end stays in place")
        // Scrolled away by the reader, growth moves nothing.
        _ = follow.changed(atEnd: false, grew: false, scrolling: true, running: true)
        #expect(follow.sizeChangeAnchor(running: true) == .top)
        let scrolls = follow.changed(atEnd: false, grew: true, scrolling: false, running: true)
        #expect(!scrolls)
    }

    @Test func aStateChangeRebuildsTheRows() throws {
        let store = store(["b"])
        let memo = SubagentRowsMemo()
        #expect(memo.rows(for: try #require(store.subagent("b"))).turn.status == .running)
        store.apply(.subagent(AgentSubagentChange(id: "b", state: .completed, at: Self.at)))
        #expect(memo.rows(for: try #require(store.subagent("b"))).turn.status == .completed)
    }

    /// 60 subagents, 20 trees 3 deep.
    func nested60() -> AgentChatStore {
        let store = AgentChatStore(source: Silent())
        store.nextFrame = nil
        for tree in 0..<20 {
            store.apply(.subagent(AgentSubagentChange(id: "r\(tree)", name: "r\(tree)", at: Self.at)))
            store.apply(.subagent(AgentSubagentChange(id: "r\(tree)-b", parent: "r\(tree)", name: "b", at: Self.at)))
            store.apply(.subagent(AgentSubagentChange(id: "r\(tree)-b-c", parent: "r\(tree)-b", name: "c", at: Self.at)))
        }
        return store
    }

    @Test func subagentsOrderIsBuiltOnceInLinearTime() {
        let store = nested60()
        let order = SubagentOrderMemo()
        let ordered = order.ordered(store.subagents)
        #expect(ordered.map(\.agent.id) == (0..<20).flatMap { ["r\($0)", "r\($0)-b", "r\($0)-b-c"] })
        #expect(ordered.map(\.depth) == Array(repeating: [0, 1, 2], count: 20).flatMap { $0 })
        #expect(order.visits == 60, "ordering 60 subagents looked at \(order.visits)")
        store.apply(.subagent(AgentSubagentChange(id: "r3-b", state: .failed, at: Self.at)))
        let again = order.ordered(store.subagents)
        #expect(order.builds == 1 && order.visits == 60, "a state change rebuilt the order")
        #expect(again.first { $0.agent.id == "r3-b" }?.agent.state == .failed, "rows show the new state")
        store.apply(.subagent(AgentSubagentChange(id: "r3-b-d", parent: "r3-b", name: "d", at: Self.at)))
        let added = order.ordered(store.subagents)
        #expect(order.builds == 2)
        #expect(added.firstIndex { $0.agent.id == "r3-b-d" } == added.firstIndex { $0.agent.id == "r3-b-c" }.map { $0 + 1 })
    }
}

/// The Event Inspector (L8): records publish once per frame, the filtered rows update by what
/// changed, and a dropped record costs only itself.
@MainActor
@Suite struct EventInspectorCoalesceTests {
    static let kinds = ["agent_message_chunk", "tool_call", "tool_call_update", "plan"]

    static func record(_ n: Int, body: String? = nil) -> JSONValue {
        .object([
            "seq": .number(Double(n + 1)), "dir": .string(n % 3 == 0 ? "out" : "in"), "kind": .string("session_update"),
            "msg": .object(["method": .string("session/update"),
                            "params": .object(["update": .object(["sessionUpdate": .string(kinds[n % kinds.count]),
                                                                   "content": .string(body ?? "text \(n) Retry")])])]),
        ])
    }

    func journal() -> AgentEventJournal {
        let journal = AgentEventJournal()
        journal.nextFrame = nil
        return journal
    }

    func brute(_ journal: AgentEventJournal, _ query: String) -> [Int] {
        journal.events.filter { $0.matches(query) }.map(\.id)
    }

    @Test func recordsArrivingInOneFrameAreOneChange() async {
        let journal = AgentEventJournal()
        let frames = TestFrames()
        journal.nextFrame = { await frames.next() }
        for n in 0..<2000 { journal.record(Self.record(n)) }
        // The records are kept at once (Copy, a detail page read them); observers hear of them once.
        #expect(journal.events.count == AgentEventJournal.limit && journal.dropped == 1500)
        await frames.fire()
        #expect(journal.changes == 1, "2000 records in one frame published \(journal.changes) changes")
        for n in 2000..<2010 { journal.record(Self.record(n)) }
        await frames.fire()
        #expect(journal.changes == 2)
    }

    @Test func anAppendCostsOneMatchAndNoneWithoutAFilter() {
        let journal = journal()
        let rows = EventInspectorRows(offMainAbove: .max)
        for n in 0..<300 { journal.record(Self.record(n)) }
        rows.setQuery("tool_call", journal: journal)
        _ = rows.rows(journal)
        var calls = rows.matchCalls
        journal.record(Self.record(301))
        #expect(rows.rows(journal).map(\.id) == brute(journal, "tool_call"))
        #expect(rows.matchCalls - calls == 1, "one append with a filter made \(rows.matchCalls - calls) matches")
        // Redraws with nothing new cost nothing.
        calls = rows.matchCalls
        for _ in 0..<10 { _ = rows.rows(journal) }
        #expect(rows.matchCalls == calls)
        rows.setQuery("", journal: journal)
        _ = rows.rows(journal)
        calls = rows.matchCalls
        for n in 302..<402 {
            journal.record(Self.record(n))
            _ = rows.rows(journal)
        }
        #expect(rows.matchCalls == calls, "100 appends with no filter made \(rows.matchCalls - calls) matches")
        #expect(rows.rows(journal).map(\.id) == journal.events.map(\.id))
    }

    @Test func droppingOldRecordsCostsTheRowsDropped() {
        let journal = journal()
        for n in 0..<5000 { journal.record(Self.record(n)) }
        #expect(journal.events.count == AgentEventJournal.limit && journal.dropped == 4500)
        #expect(journal.moved <= 2 * 5000, "5000 records moved \(journal.moved) kept rows to drop old ones")
    }

    @Test func theDetailEncodesItsRecordOnce() {
        let journal = journal()
        journal.record(Self.record(1, body: String(repeating: "x", count: 30_000)))
        let memo = EventJSONMemo()
        let event = journal.events[journal.events.startIndex]
        for _ in 0..<5 { _ = memo.json(for: event) }
        #expect(memo.encodes == 1, "5 redraws encoded \(memo.encodes) times")
        let json = memo.json(for: event)
        #expect(json.total != nil && json.text.count == AgentEventJournal.maxCharacters)
    }

    @Test func countsAndRowsMatchABruteForceRecomputeThroughRandomChanges() {
        var generator = SystemRandomNumberGenerator()
        let journal = journal()
        let rows = EventInspectorRows(offMainAbove: .max)
        let queries = ["", "tool_call", "TOOL", "retry", "out", "plan · seq", "zzz", "seq 4"]
        var seq = 0
        var droppedSinceClear = 0
        for step in 0..<400 {
            let roll = Int.random(in: 0..<100, using: &generator)
            if roll < 2 {
                journal.clear()
                droppedSinceClear = 0
            } else if roll < 8 {
                rows.setQuery(queries.randomElement(using: &generator)!, journal: journal)
            } else {
                let burst = Int.random(in: 1...40, using: &generator)
                for _ in 0..<burst {
                    let before = journal.events.count
                    journal.record(Self.record(seq))
                    seq += 1
                    if journal.events.count == before { droppedSinceClear += 1 }
                }
            }
            let shown = rows.rows(journal)
            #expect(shown.map(\.id) == brute(journal, rows.query), "step \(step): rows differ for '\(rows.query)'")
            #expect(journal.dropped == droppedSinceClear)
            #expect(journal.events.count <= AgentEventJournal.limit)
            // Copy as JSON Lines: the shown rows, oldest first.
            #expect(journal.jsonLines(Array(shown)) == journal.jsonLines(journal.events.filter { $0.matches(rows.query) }))
        }
    }

    @Test func aStaleQueryNeverLands() async {
        let journal = journal()
        for n in 0..<500 { journal.record(Self.record(n, body: String(repeating: "pad ", count: 200) + "Retry \(n)")) }
        let rows = EventInspectorRows(offMainAbove: 0)
        rows.setQuery("tool", journal: journal)
        rows.setQuery("tool_call_update", journal: journal)
        // Records arrive while the filter runs.
        for n in 500..<520 { journal.record(Self.record(n)) }
        await rows.settled()
        #expect(rows.shownQueries.last == "tool_call_update")
        #expect(!rows.shownQueries.contains("tool"), "an older query's result was shown: \(rows.shownQueries)")
        #expect(rows.rows(journal).map(\.id) == brute(journal, "tool_call_update"))
    }

    /// While a new query's filter runs off the main thread, the rows (what the list draws and
    /// Copy as JSON Lines copies) are one query's: never the last query's rows mixed with newer
    /// records matched against the new one.
    @Test func whileAFilterRunsTheRowsAreOneQuerysRows() async {
        let journal = journal()
        let pad = String(repeating: "pad ", count: 200)
        for n in 0..<400 { journal.record(Self.record(n, body: pad + (n % 2 == 0 ? "alpha" : "beta"))) }
        let rows = EventInspectorRows(offMainAbove: 0)
        rows.setQuery("alpha", journal: journal)
        await rows.settled()
        #expect(rows.rows(journal).map(\.id) == brute(journal, "alpha"))
        // The new query's scan is in flight (this test holds the main actor, so it cannot land).
        rows.setQuery("beta", journal: journal)
        for n in 400..<440 { journal.record(Self.record(n, body: n % 2 == 0 ? "alpha" : "beta")) }
        let shown = Array(rows.rows(journal))
        let allAlpha = shown.allSatisfy { $0.matches("alpha") }
        let allBeta = shown.allSatisfy { $0.matches("beta") }
        #expect(allAlpha || allBeta,
                "the rows mix two queries: \(shown.filter { $0.matches("alpha") }.count) match alpha, \(shown.filter { $0.matches("beta") }.count) match beta")
        if allAlpha { #expect(shown.map(\.id) == brute(journal, "alpha"), "the shown query's rows, newer records too") }
        await rows.settled()
        #expect(rows.rows(journal).map(\.id) == brute(journal, "beta"), "the new query's rows once it lands")
        // Records after it lands match the new query.
        for n in 440..<450 { journal.record(Self.record(n, body: n % 2 == 0 ? "alpha" : "beta")) }
        #expect(rows.rows(journal).map(\.id) == brute(journal, "beta"))
    }

    /// Clear while a filter runs: the landed rows are the new query's over the records since.
    @Test func clearWhileAFilterRunsLandsTheNewQueryOnTheRecordsSince() async {
        let journal = journal()
        let pad = String(repeating: "pad ", count: 200)
        for n in 0..<300 { journal.record(Self.record(n, body: pad + (n % 2 == 0 ? "alpha" : "beta"))) }
        let rows = EventInspectorRows(offMainAbove: 0)
        rows.setQuery("beta", journal: journal)
        journal.clear()
        for n in 300..<310 { journal.record(Self.record(n, body: n % 2 == 0 ? "alpha" : "beta")) }
        await rows.settled()
        #expect(rows.rows(journal).map(\.id) == brute(journal, "beta"))
    }

    final class Flag: @unchecked Sendable {
        var on = false
    }

    /// What the screen's body reads (`rows`, the count) hears of a new query, a record and Clear.
    @Test func theScreenHearsOfQueriesRecordsAndClear() {
        let journal = journal()
        let rows = EventInspectorRows(offMainAbove: .max)
        for n in 0..<10 { journal.record(Self.record(n)) }
        func redraws(_ change: () -> Void) -> Bool {
            let flag = Flag()
            withObservationTracking {
                _ = rows.rows(journal)
                _ = journal.events.count
            } onChange: { flag.on = true }
            change()
            return flag.on
        }
        #expect(redraws { rows.setQuery("tool", journal: journal) }, "a new query redraws")
        #expect(redraws { rows.setQuery("", journal: journal) }, "clearing the query redraws")
        #expect(redraws { journal.record(Self.record(10)) }, "a record redraws")
        #expect(redraws { journal.clear() }, "Clear redraws")
    }

    @Test func clearEmptiesAndLaterRecordsShowAtOnce() {
        let journal = journal()
        let rows = EventInspectorRows(offMainAbove: .max)
        for n in 0..<(AgentEventJournal.limit + 1) { journal.record(Self.record(n)) }
        #expect(journal.dropped == 1 && rows.rows(journal).count == AgentEventJournal.limit)
        journal.clear()
        #expect(rows.rows(journal).isEmpty && journal.dropped == 0 && journal.events.isEmpty)
        journal.record(Self.record(9000))
        #expect(rows.rows(journal).map(\.seq) == [9001])
    }

    @Test func aRecordOverTheCapKeepsItsKindAndSeq() {
        let journal = journal()
        journal.record(Self.record(7, body: String(repeating: "y", count: AgentEventJournal.maxRecordBytes + 10)))
        let event = journal.events[journal.events.startIndex]
        #expect(journal.events.count == 1 && event.seq == 8 && event.line.contains("only its kind and seq"))
    }

    // MARK: Held while the reader is away from the top (cmux#13742)

    /// Away from the top the rows hold still: new records are counted, not shown, and rows the
    /// journal drops stay as stubs (their bodies let go at once). The hold's end lands them: the
    /// rows are the journal's again, pruned to it.
    @Test(arguments: ["", "tool_call"])
    func aHeldListHoldsStillAndLandsTheNewRecordsTogether(_ query: String) {
        let journal = journal()
        let rows = EventInspectorRows(offMainAbove: .max)
        let big = String(repeating: "body ", count: 200)
        for n in 0..<AgentEventJournal.limit { journal.record(Self.record(n, body: big)) }
        rows.setQuery(query, journal: journal)
        let shown = rows.rows(journal).map(\.id)
        rows.setHolding(true, journal: journal)
        for n in AgentEventJournal.limit..<(AgentEventJournal.limit + 60) { journal.record(Self.record(n)) }
        let held = rows.rows(journal)
        #expect(held.map(\.id) == shown, "the rows hold still while held")
        let newMatches = (AgentEventJournal.limit..<(AgentEventJournal.limit + 60)).filter { n in
            query.isEmpty || AgentInspectorEvent(id: n, record: Self.record(n)).matches(query)
        }.count
        #expect(rows.heldCount == newMatches, "the pill counts the new matching records")
        // The 60 dropped rows' bodies are let go: what the rows keep is the journal's plus small stubs.
        let dropped = held.filter { $0.id < journal.firstID }
        let allStubs = dropped.allSatisfy { $0.isStub }
        #expect(!dropped.isEmpty && allStubs, "dropped rows are kept as stubs")
        #expect(dropped.allSatisfy { $0.line.utf8.count < 400 }, "a stub keeps no body")
        #expect(rows.stubbed == dropped.count)
        let keptBytes = held.reduce(0) { $0 + $1.line.utf8.count }
        #expect(keptBytes <= journal.keptBytes + dropped.count * 400, "held rows keep \(keptBytes) bytes, the journal \(journal.keptBytes)")
        // A stub's row reads as its record did.
        let original = AgentInspectorEvent(id: dropped[0].id, record: Self.record(dropped[0].id, body: big))
        #expect(dropped[0].title == original.title && dropped[0].dir == original.dir && dropped[0].kind == original.kind)
        #expect(dropped[0].json.text.contains(AgentInspectorEvent.droppedNote), "its detail says it was dropped")
        rows.setHolding(false, journal: journal)
        #expect(rows.rows(journal).map(\.id) == brute(journal, query), "the hold's end lands the new records, pruned to the journal")
        #expect(rows.heldCount == 0)
        let stubsLeft = rows.rows(journal).filter { $0.isStub }.count
        #expect(stubsLeft == 0, "no stub stays once the hold ends (\(stubsLeft) left)")
    }

    /// A new query or Clear while held: the rows are the journal's (nothing held stays behind).
    @Test func aQueryOrClearWhileHeldShowsTheJournal() {
        let journal = journal()
        let rows = EventInspectorRows(offMainAbove: .max)
        for n in 0..<100 { journal.record(Self.record(n)) }
        _ = rows.rows(journal)
        rows.setHolding(true, journal: journal)
        for n in 100..<120 { journal.record(Self.record(n)) }
        _ = rows.rows(journal)
        #expect(rows.heldCount == 20)
        rows.setQuery("tool_call", journal: journal)
        #expect(rows.rows(journal).map(\.id) == brute(journal, "tool_call") && rows.heldCount == 0)
        for n in 120..<130 { journal.record(Self.record(n)) }
        _ = rows.rows(journal)
        journal.clear()
        #expect(rows.rows(journal).isEmpty && rows.heldCount == 0)
        for n in 130..<135 { journal.record(Self.record(n)) }
        _ = rows.rows(journal)
        rows.setHolding(false, journal: journal)
        #expect(rows.rows(journal).map(\.id) == brute(journal, "tool_call"))
    }

    @Test func theByteBudgetHoldsWithTheMemo() {
        let journal = journal()
        let rows = EventInspectorRows(offMainAbove: .max)
        let big = String(repeating: "z", count: 200 << 10)
        for n in 0..<60 {
            journal.record(Self.record(n, body: big))
            _ = rows.rows(journal)
        }
        #expect(journal.events.reduce(0) { $0 + $1.line.utf8.count } <= AgentEventJournal.maxBytes)
        #expect(rows.rows(journal).count == journal.events.count)
    }
}

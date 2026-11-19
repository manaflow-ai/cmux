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
                _ = journal.count
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

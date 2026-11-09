import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

@Suite struct AcpmuxReplayTests {
    @Test func overflowDiscardsTheWholeReplayRatherThanPartialDeltas() {
        var replay = AcpmuxReplay<String>(limit: 3)
        replay.append(["turn", "first chunk"])
        replay.append(["second chunk"])
        #expect(replay.events == ["turn", "first chunk", "second chunk"])
        #expect(!replay.requiresResync)
        replay.append(["third chunk"])
        #expect(replay.events.isEmpty)
        #expect(replay.requiresResync)
        replay.append(Array(repeating: "later chunk", count: 10_000))
        #expect(replay.events.isEmpty, "an expired replay never grows again")
    }

    @Test func olderPagesKeepChronologicalOrderAndShareTheBudget() {
        var replay = AcpmuxReplay<Int>(limit: 4)
        replay.append([3, 4])
        replay.prepend([1, 2])
        #expect(replay.events == [1, 2, 3, 4])
        replay.prepend([0])
        #expect(replay.requiresResync)
        #expect(replay.events.isEmpty)
        replay.prepend([-1])
        replay.append([5])
        #expect(replay.events.isEmpty)
    }

    @Test func anOversizedHistoryBatchAlsoRequiresResync() {
        var replay = AcpmuxReplay<Int>(limit: 3)
        replay.append([1, 2, 3, 4])
        #expect(replay.requiresResync)
        #expect(replay.events.isEmpty)
    }
}

@MainActor
@Suite struct AcpmuxReplayResyncTests {
    enum Overflow: Sendable, CaseIterable, Equatable { case events, pendingChunk, oversizedChunk }

    @Test(.timeLimit(.minutes(1)), arguments: Overflow.allCases)
    func newReaderResyncsWithoutInterruptingTheExistingReader(overflow: Overflow) async throws {
        let attaches = ChatOpenSnapshotLiveTests.Attaches()
        let link = MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            switch method {
            case "initialize": return [reply(#"{"protocolVersion":1}"#)]
            case "_acpmux/watch": return [reply(#"{"sessions":[]}"#)]
            case "_acpmux/attach":
                let params = object["params"] as? [String: Any]
                let after = (params?["afterSeq"] as? NSNumber)?.intValue ?? 0
                attaches.append(after)
                let history = ChatOpenSnapshotLiveTests.turnRecords(1).joined(separator: ",")
                return [reply(#"{"session":{"sessionId":"s1","status":"idle","pending":[]},"hasMore":\#(after == 0),"events":[\#(history)]}"#)]
            case "_acpmux/events":
                let history = ChatOpenSnapshotLiveTests.turnRecords(0).joined(separator: ",")
                return [reply(#"{"hasMore":false,"events":[\#(history)]}"#)]
            case "session/set_model":
                return [Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"model unavailable"}}"#.utf8)]
            case "_test/live":
                return [reply("{}"), Data(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s1","seq":100000,"dir":"mux","kind":"user_message","msg":{"text":"live","promptId":"live","turnId":"live"}}}"#.utf8)]
            default: return [reply("{}")]
            }
        }
        let hub = AcpmuxHub()
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        let source = hub.source(sessionID: "s1", summary: ChatOpenSnapshotLiveTests.summary)
        // The hub routes through a weak-self notification pump, and its source registry
        // is weak too. Keep both owners alive until the separately delivered live event
        // reaches each reader, as the app's coordinator and chat store do.
        defer { withExtendedLifetime((hub, source)) {} }
        var first = source.events().makeAsyncIterator()
        let firstEvent = try #require(await first.next())
        guard case .batch = firstEvent else {
            Issue.record("the initial reader did not receive a history batch")
            return
        }

        // Exercise both count overflow and a chunk whose flush is what expires replay.
        let extra = overflow == .events ? 1 : 0
        if overflow != .oversizedChunk {
            let remaining = AcpmuxSessionSource.replayEventLimit - source.replayCount
            for n in 0..<(remaining + extra) {
                source.receive(record: .object([
                    "seq": .number(Double(n + 100)), "dir": .string("mux"), "kind": .string("turn_started"),
                    "msg": .object(["turnId": .string("t0")]),
                ]))
            }
        }
        if overflow != .events {
            let text = overflow == .oversizedChunk
                ? String(repeating: "x", count: AcpmuxSessionSource.openBytes + 1) : "pending"
            source.receive(record: Self.chunk(text, seq: 90_000))
        }
        var second = source.events().makeAsyncIterator()
        let secondEvent = try #require(await second.next())
        try #require(attaches.all == [0, 0], "the new reader fetches a snapshot, not a partial afterSeq replay")
        guard case .batch(let history) = secondEvent else {
            Issue.record("the resynced reader did not receive one complete history batch")
            return
        }
        #expect(ChatOpenSnapshotLiveTests.userMessages(history) == ["t1"])

        source.receive(record: Self.chunk("after expiry", seq: 90_001))
        #expect(source.replayCount == 0, "an expired source keeps delivering but retains no new chunks")

        // The store still holds the original source after its event stream resyncs.
        // Its actions must reach the new reader, not disappear into the old source.
        // Drain the overflow before checking actions: a collector task can be
        // thousands of buffered events behind on a loaded full-kit run. Each
        // wait consumes the actual FIFO; the test time limit bounds a hang.
        try await Self.nextLiveEvent(&first) {
            if case .update(.agentMessageChunk(let text, _)) = $0 { text == "after expiry" }
            else { false }
        }
        source.send(.setModel("unavailable"))
        try await Self.nextLiveEvent(&first, matching: Self.hasModelError)
        try await Self.nextLiveEvent(&second, matching: Self.hasModelError)
        source.loadEarlierHistory()
        try await Self.nextLiveEvent(&first, matching: Self.hasOlderTurn)
        try await Self.nextLiveEvent(&second, matching: Self.hasOlderTurn)

        source.refreshPermissions()
        try await Self.nextLiveEvent(&first, allowingRefresh: true, matching: Self.isRefresh)
        try await Self.nextLiveEvent(&second, allowingRefresh: true, matching: Self.isRefresh)
        #expect(attaches.all.suffix(2).sorted() == [10, 90_001], "both replay generations refresh their own state")

        _ = try await hub.request("_test/live", .object([:]))
        try await Self.nextLiveEvent(&first, matching: Self.isLiveMessage)
        try await Self.nextLiveEvent(&second, matching: Self.isLiveMessage)
        // Disconnect after the assertions; releasing the iterators ends their readers.
        await hub.bind(nil)
    }

    private nonisolated static func nextLiveEvent(
        _ iterator: inout AsyncStream<AgentSessionEvent>.Iterator,
        allowingRefresh: Bool = false,
        matching predicate: (AgentSessionEvent) -> Bool
    ) async throws {
        while let event = await iterator.next() {
            if case .batch(let events) = event {
                #expect(allowingRefresh, "resync repeated history into an existing reader")
                #expect(ChatOpenSnapshotLiveTests.userMessages(events).isEmpty,
                        "permission refresh must not replay already received turns")
            }
            if predicate(event) { return }
        }
        try Task.checkCancellation()
        Issue.record("the reader ended before the expected live event")
        throw CancellationError()
    }

    private nonisolated static func hasModelError(_ event: AgentSessionEvent) -> Bool {
        if case .clientError(let text) = event { text.localizedCaseInsensitiveContains("model unavailable") }
        else { false }
    }

    private nonisolated static func hasOlderTurn(_ event: AgentSessionEvent) -> Bool {
        if case .earlierPage(let page, _) = event { ChatOpenSnapshotLiveTests.userMessages(page).contains("t0") }
        else { false }
    }

    private nonisolated static func isRefresh(_ event: AgentSessionEvent) -> Bool {
        if case .batch(let events) = event {
            events.contains { if case .status = $0 { true } else { false } }
        } else { false }
    }

    private nonisolated static func isLiveMessage(_ event: AgentSessionEvent) -> Bool {
        if case .userMessage(_, _, let turn, _, _) = event { turn == "live" } else { false }
    }

    private static func chunk(_ text: String, seq: Int) -> JSONValue {
        .object([
            "seq": .number(Double(seq)), "dir": .string("in"), "kind": .string("agent_message_chunk"),
            "msg": .object([
                "method": .string("session/update"),
                "params": .object(["update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["type": .string("text"), "text": .string(text)]),
                ])]),
            ]),
        ])
    }

}

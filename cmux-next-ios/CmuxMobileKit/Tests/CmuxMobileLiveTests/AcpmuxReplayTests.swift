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
    enum Overflow: Sendable, CaseIterable { case events, pendingChunk, oversizedChunk }

    @Test(arguments: Overflow.allCases)
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
                attaches.append((params?["afterSeq"] as? NSNumber)?.intValue ?? 0)
                let history = ChatOpenSnapshotLiveTests.turnRecords(0).joined(separator: ",")
                return [reply(#"{"session":{"sessionId":"s1","status":"idle","pending":[]},"hasMore":false,"events":[\#(history)]}"#)]
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
        let (first, firstTask) = ChatOpenSnapshotLiveTests.collect(source.events())
        defer { firstTask.cancel() }
        await ChatOpenSnapshotLiveTests.waitUntil { first.events.contains { if case .batch = $0 { true } else { false } } }
        try #require(first.events.contains { if case .batch = $0 { true } else { false } })

        // Exercise both count overflow and a chunk whose flush is what expires replay.
        let extra = overflow == .events ? 1 : 0
        if overflow != .oversizedChunk {
            let remaining = AcpmuxSessionSource.replayEventLimit - source.replayCount
            for n in 0..<(remaining + extra) {
                source.receive(record: .object([
                    "seq": .number(Double(n + 10)), "dir": .string("mux"), "kind": .string("turn_started"),
                    "msg": .object(["turnId": .string("t0")]),
                ]))
            }
        }
        if overflow != .events {
            let text = overflow == .oversizedChunk
                ? String(repeating: "x", count: AcpmuxSessionSource.openBytes + 1) : "pending"
            source.receive(record: Self.chunk(text, seq: 90_000))
        }
        let (second, secondTask) = ChatOpenSnapshotLiveTests.collect(source.events())
        defer { secondTask.cancel() }
        await ChatOpenSnapshotLiveTests.waitUntil { second.events.contains { if case .batch = $0 { true } else { false } } }
        try #require(attaches.all == [0, 0], "the new reader fetches a snapshot, not a partial afterSeq replay")
        guard case .batch(let history)? = second.events.first else {
            Issue.record("the resynced reader did not receive one complete history batch")
            return
        }
        #expect(ChatOpenSnapshotLiveTests.userMessages(history) == ["t0"])
        #expect(first.events.filter { if case .batch = $0 { true } else { false } }.count == 1,
                "resync never repeats history into the existing reader")

        source.receive(record: Self.chunk("after expiry", seq: 90_001))
        #expect(source.replayCount == 0, "an expired source keeps delivering but retains no new chunks")

        _ = try await hub.request("_test/live", .object([:]))
        await ChatOpenSnapshotLiveTests.waitUntil {
            ChatOpenSnapshotLiveTests.userMessages(first.events).contains("live")
                && ChatOpenSnapshotLiveTests.userMessages(second.events).contains("live")
        }
        #expect(ChatOpenSnapshotLiveTests.userMessages(first.events).contains("live"))
        #expect(ChatOpenSnapshotLiveTests.userMessages(second.events).contains("live"))
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

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

    @Test func anOversizedHistoryBatchAlsoRequiresResync() {
        var replay = AcpmuxReplay<Int>(limit: 3)
        replay.append([1, 2, 3, 4])
        #expect(replay.requiresResync)
        #expect(replay.events.isEmpty)
    }
}

@MainActor
@Suite struct AcpmuxReplayResyncTests {
    @Test func newReaderResyncsWithoutInterruptingTheExistingReader() async throws {
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
        for _ in 0..<2000 where first.events.isEmpty { await Task.yield() }
        try #require(!first.events.isEmpty)

        // Stream past the cache budget while the original reader remains attached.
        for n in 0..<(AcpmuxSessionSource.maxHistory + 1) {
            source.receive(record: .object([
                "seq": .number(Double(n + 10)), "dir": .string("mux"), "kind": .string("turn_started"),
                "msg": .object(["turnId": .string("t0")]),
            ]))
        }
        let (second, secondTask) = ChatOpenSnapshotLiveTests.collect(source.events())
        defer { secondTask.cancel() }
        for _ in 0..<2000 where second.events.isEmpty { await Task.yield() }
        try #require(attaches.all == [0, 0], "the new reader fetches a snapshot, not a partial afterSeq replay")
        guard case .batch(let history)? = second.events.first else {
            Issue.record("the resynced reader did not receive one complete history batch")
            return
        }
        #expect(ChatOpenSnapshotLiveTests.userMessages(history) == ["t0"])
        #expect(first.events.filter { if case .batch = $0 { true } else { false } }.count == 1,
                "resync never repeats history into the existing reader")

        _ = try await hub.request("_test/live", .object([:]))
        for _ in 0..<2000 where !ChatOpenSnapshotLiveTests.userMessages(first.events).contains("live")
            || !ChatOpenSnapshotLiveTests.userMessages(second.events).contains("live") {
            await Task.yield()
        }
        #expect(ChatOpenSnapshotLiveTests.userMessages(first.events).contains("live"))
        #expect(ChatOpenSnapshotLiveTests.userMessages(second.events).contains("live"))
    }
}

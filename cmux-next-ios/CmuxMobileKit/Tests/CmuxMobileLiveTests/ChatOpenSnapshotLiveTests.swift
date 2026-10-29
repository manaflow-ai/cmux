import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Opening an agent chat over acpmux: the `_acpmux/attach` reply is the replay
/// boundary. Its page reaches the chat as one `.batch` (drawn in place on open),
/// records after the reply arrive one by one (live), and a reattach catches up
/// from the last seq as one batch, never sending what was shown again.
@MainActor
@Suite struct ChatOpenSnapshotLiveTests {
    /// Every attach, in order, with its `afterSeq` (0: none).
    final class Attaches: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [Int] = []
        func append(_ afterSeq: Int) { lock.withLock { seen.append(afterSeq) } }
        var all: [Int] { lock.withLock { seen } }
    }

    nonisolated static let turns = 40

    /// One finished turn: user message, start, two answer chunks, result (5 records).
    nonisolated static func turnRecords(_ n: Int) -> [String] {
        let seq = n * 5 + 1
        return [
            #"{"sessionId":"s1","seq":\#(seq),"at":1,"dir":"mux","kind":"user_message","msg":{"text":"prompt \#(n)","promptId":"p\#(n)","turnId":"t\#(n)"}}"#,
            #"{"sessionId":"s1","seq":\#(seq + 1),"at":2,"dir":"mux","kind":"turn_started","msg":{"turnId":"t\#(n)"}}"#,
            #"{"sessionId":"s1","seq":\#(seq + 2),"at":3,"dir":"in","kind":"agent_message_chunk","msg":{"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"answer "}}}}}"#,
            #"{"sessionId":"s1","seq":\#(seq + 3),"at":3,"dir":"in","kind":"agent_message_chunk","msg":{"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\#(n)"}}}}}"#,
            #"{"sessionId":"s1","seq":\#(seq + 4),"at":4,"dir":"mux","kind":"turn_result","msg":{"status":"completed","turnId":"t\#(n)"}}"#,
        ]
    }

    /// A fake acpmux: `turns` finished turns of history, then one live chunk of a
    /// new turn after the first attach's reply. A reattach (`afterSeq`) gets one
    /// more finished turn that ran while the link was down.
    nonisolated static func fakeAcpmux(_ attaches: Attaches) -> MockMacLink {
        MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            switch method {
            case "initialize": return [reply(#"{"protocolVersion":1}"#)]
            case "_acpmux/watch": return [reply(#"{"sessions":[{"sessionId":"s1","name":"Fix","harness":"codex","cwd":"/tmp/w","status":"idle"}]}"#)]
            case "_acpmux/attach":
                let params = object["params"] as? [String: Any]
                let after = (params?["afterSeq"] as? NSNumber)?.intValue ?? 0
                attaches.append(after)
                if after > 0 {
                    // Missed while the link was down: one more turn.
                    let missed = turnRecords(turns + 1).joined(separator: ",")
                    return [reply(#"{"session":{"sessionId":"s1","status":"idle","pending":[]},"hasMore":false,"events":[\#(missed)]}"#)]
                }
                let history = (0..<turns).flatMap(turnRecords).joined(separator: ",")
                let liveSeq = turns * 5 + 1
                return [
                    reply(#"{"session":{"sessionId":"s1","status":"running","pending":[]},"hasMore":false,"events":[\#(history)]}"#),
                    Data(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s1","seq":\#(liveSeq),"at":5,"dir":"mux","kind":"user_message","msg":{"text":"live prompt","promptId":"pl","turnId":"tl"}}}"#.utf8),
                ]
            default:
                return [reply("{}")]
            }
        }
    }

    static let summary = AgentSessionSummary(id: "s7", name: "Fix", harness: "codex", agentName: "Codex", cwd: "/tmp/w",
                                             workspaceTitle: "w", macName: "mini")

    final class Collected {
        var events: [AgentSessionEvent] = []
    }

    static func collect(_ stream: AsyncStream<AgentSessionEvent>) -> (Collected, Task<Void, Never>) {
        let collected = Collected()
        let task = Task { @MainActor in
            for await event in stream { collected.events.append(event) }
        }
        return (collected, task)
    }

    static func userMessages(_ events: [AgentSessionEvent]) -> [String] {
        events.compactMap { if case .userMessage(_, _, let turn, _, _) = $0 { turn } else { nil } }
    }

    @Test func attachPageArrivesAsOneBatchThenLiveRecords() async throws {
        let attaches = Attaches()
        let hub = AcpmuxHub()
        await hub.bind(try await Self.fakeAcpmux(attaches).openChannel(service: "acpmux", args: [:]))
        let source = hub.source(sessionID: "s1", summary: Self.summary)
        let (collected, task) = Self.collect(source.events())
        defer { task.cancel() }
        for _ in 0..<2000 where !Self.userMessages(collected.events).contains("tl") { await Task.yield() }

        // The first event is the whole history, as one change.
        guard case .batch(let history)? = collected.events.first else {
            Issue.record("history did not arrive as one batch: \(collected.events.prefix(3))")
            return
        }
        #expect(Self.userMessages(history) == (0..<Self.turns).map { "t\($0)" })
        // No replayed record arrives on its own (each would be drawn as a live insert).
        let loose = Self.userMessages(Array(collected.events.dropFirst()))
        #expect(loose == ["tl"], "records outside the history batch: \(loose)")
    }

    /// The chat opened again (a new store on the same source) gets what the
    /// source holds as one batch, not record by record.
    @Test func secondReaderGetsOneBatch() async throws {
        let attaches = Attaches()
        let hub = AcpmuxHub()
        await hub.bind(try await Self.fakeAcpmux(attaches).openChannel(service: "acpmux", args: [:]))
        let source = hub.source(sessionID: "s1", summary: Self.summary)
        let (first, firstTask) = Self.collect(source.events())
        defer { firstTask.cancel() }
        for _ in 0..<2000 where !Self.userMessages(first.events).contains("tl") { await Task.yield() }

        let (second, secondTask) = Self.collect(source.events())
        defer { secondTask.cancel() }
        for _ in 0..<200 where second.events.isEmpty { await Task.yield() }
        #expect(second.events.count == 1)
        guard case .batch(let replay)? = second.events.first else {
            Issue.record("a second reader got loose records: \(second.events.prefix(3))")
            return
        }
        #expect(Self.userMessages(replay) == (0..<Self.turns).map { "t\($0)" } + ["tl"])
    }

    /// A reattach after a link drop: `afterSeq` is the last seq shown, the missed turn
    /// comes as one batch, and nothing shown before is sent again.
    @Test func reattachCatchesUpAsOneBatchWithoutResending() async throws {
        let attaches = Attaches()
        let link = Self.fakeAcpmux(attaches)
        let hub = AcpmuxHub()
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        let source = hub.source(sessionID: "s1", summary: Self.summary)
        let store = AgentChatStore(source: source)
        for _ in 0..<2000 where store.turns.last?.id != "tl" { await Task.yield() }
        #expect(store.turns.count == Self.turns + 1)
        let (collected, task) = Self.collect(source.events())
        defer { task.cancel() }
        for _ in 0..<200 where collected.events.isEmpty { await Task.yield() }
        let before = collected.events.count

        // The link drops and comes back on a new channel.
        await hub.bind(nil)
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        let missed = "t\(Self.turns + 1)"
        for _ in 0..<2000 where store.turns.last?.id != missed { await Task.yield() }

        #expect(attaches.all == [0, Self.turns * 5 + 1])
        let after = Array(collected.events.dropFirst(before))
        let batches = after.compactMap { if case .batch(let events) = $0 { events } else { nil } }
        #expect(batches.count == 1)
        #expect(Self.userMessages(batches.first ?? []) == [missed])
        // Nothing already shown arrived again, loose or batched.
        #expect(Self.userMessages(after) == [])
        #expect(store.turns.map(\.id) == (0..<Self.turns).map { "t\($0)" } + ["tl", missed])
        // The store drew the catch-up in place.
        #expect(store.isReplayed(missed))
        #expect(store.isReplayed("t0"))
    }

    /// A reattach whose missed records span more than one page (a phone suspended while
    /// a long turn streamed): the attach reply is the first page with `hasMore`, and the
    /// chat reads on with `_acpmux/events` `afterSeq` until the log's end. It used to stop
    /// after the first page: the next live record moved `lastSeq` past the rest, and the
    /// answer lost everything in between (1405 of 3000 chunks on a live rig).
    @Test func reattachPagesForwardThroughTheWholeGap() async throws {
        let missedTurns = 3
        let firstMissed = Self.turns + 1
        let link = MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            let params = object["params"] as? [String: Any]
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            // One missed turn (5 records) per page, oldest first: the turn after the one
            // holding seq `after` (turn n holds seqs 5n+1...5n+5).
            func page(after: Int) -> (String, Bool) {
                let turn = max((after - 1) / 5 + 1, firstMissed)
                let last = firstMissed + missedTurns - 1
                return (Self.turnRecords(turn).joined(separator: ","), turn < last)
            }
            switch method {
            case "initialize": return [reply(#"{"protocolVersion":1}"#)]
            case "_acpmux/watch": return [reply(#"{"sessions":[{"sessionId":"s1","name":"Fix","harness":"codex","cwd":"/tmp/w","status":"idle"}]}"#)]
            case "_acpmux/attach":
                let after = (params?["afterSeq"] as? NSNumber)?.intValue ?? 0
                if after > 0 {
                    let (records, more) = page(after: after)
                    return [reply(#"{"session":{"sessionId":"s1","status":"idle","pending":[]},"hasMore":\#(more),"events":[\#(records)]}"#)]
                }
                let history = (0..<Self.turns).flatMap(Self.turnRecords).joined(separator: ",")
                return [reply(#"{"session":{"sessionId":"s1","status":"idle","pending":[]},"hasMore":false,"events":[\#(history)]}"#)]
            case "_acpmux/events":
                let after = (params?["afterSeq"] as? NSNumber)?.intValue ?? 0
                let (records, more) = page(after: after)
                return [reply(#"{"hasMore":\#(more),"events":[\#(records)]}"#)]
            default:
                return [reply("{}")]
            }
        }
        let hub = AcpmuxHub()
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        let source = hub.source(sessionID: "s1", summary: Self.summary)
        let store = AgentChatStore(source: source)
        for _ in 0..<2000 where store.turns.count < Self.turns { await Task.yield() }
        #expect(store.turns.count == Self.turns)

        await hub.bind(nil)
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        let last = "t\(firstMissed + missedTurns - 1)"
        for _ in 0..<4000 where store.turns.last?.id != last { await Task.yield() }

        let missed = (firstMissed..<(firstMissed + missedTurns)).map { "t\($0)" }
        #expect(Array(store.turns.map(\.id).suffix(missedTurns)) == missed)
        #expect(store.turns.count == Self.turns + missedTurns)
    }

    /// A chat whose history is longer than the attach keeps says so: its first turn shown
    /// is not where the session started. It used to read "Session started <that turn>".
    @Test(arguments: [true, false])
    func cappedHistorySaysEarlierMessagesExist(_ long: Bool) async throws {
        // Pages of 80 turns (400 records), newest first; a long chat has more than the cap.
        let total = long ? 1000 : 120
        let link = MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            let params = object["params"] as? [String: Any]
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            // The 80 turns before turn `end` (exclusive), and whether older ones exist.
            func page(before end: Int) -> (String, Bool) {
                let start = max(0, end - 80)
                return ((start..<end).flatMap(Self.turnRecords).joined(separator: ","), start > 0)
            }
            switch method {
            case "initialize": return [reply(#"{"protocolVersion":1}"#)]
            case "_acpmux/watch": return [reply(#"{"sessions":[{"sessionId":"s1","name":"Fix","harness":"codex","cwd":"/tmp/w","status":"idle"}]}"#)]
            case "_acpmux/attach":
                let (records, more) = page(before: total)
                return [reply(#"{"session":{"sessionId":"s1","status":"idle","pending":[]},"hasMore":\#(more),"events":[\#(records)]}"#)]
            case "_acpmux/events":
                let before = (params?["beforeSeq"] as? NSNumber)?.intValue ?? 1
                let (records, more) = page(before: (before - 1) / 5)
                return [reply(#"{"hasMore":\#(more),"events":[\#(records)]}"#)]
            default:
                return [reply("{}")]
            }
        }
        let hub = AcpmuxHub()
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        let store = AgentChatStore(source: hub.source(sessionID: "s1", summary: Self.summary))
        let shown = long ? 400 : total  // 2000 records kept: the newest 400 turns
        // Five pages through the mock link: wait with the main actor free (a yield loop
        // this long starves the other main-actor suites running beside it).
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(30)
        while store.turns.count < shown, clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.turns.count == shown)
        #expect(store.turns.first?.id == "t\(total - shown)")
        #expect(store.hasEarlierHistory == long)
    }

    /// A new turn's ask that arrives while the attach is in flight (held), and that the
    /// reply also lists as pending, lands once, on that turn, after its turn exists.
    @Test func askHeldDuringAttachLandsOnItsOwnTurn() async throws {
        let link = MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            let request = #"{"toolCall":{"toolCallId":"c","title":"rm","kind":"execute"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"deny","name":"Deny","kind":"reject_once"}]}"#
            func event(_ record: String) -> Data { Data(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":\#(record)}"#.utf8) }
            switch method {
            case "initialize": return [reply(#"{"protocolVersion":1}"#)]
            case "_acpmux/watch": return [reply(#"{"sessions":[{"sessionId":"s1","name":"Fix","harness":"codex","cwd":"/tmp/w","status":"idle"}]}"#)]
            case "_acpmux/attach":
                let history = Self.turnRecords(0).joined(separator: ",")
                return [
                    // Live while the request is in flight: a new turn and its ask.
                    event(#"{"sessionId":"s1","seq":6,"at":5,"dir":"mux","kind":"user_message","msg":{"text":"next","promptId":"p1","turnId":"t1"}}"#),
                    event(#"{"sessionId":"s1","seq":7,"at":5,"dir":"mux","kind":"turn_started","msg":{"turnId":"t1"}}"#),
                    event(#"{"sessionId":"s1","seq":8,"at":5,"dir":"mux","kind":"permission_request","msg":{"permissionId":"perm","request":\#(request)}}"#),
                    reply(#"{"session":{"sessionId":"s1","status":"waiting","pending":[{"permissionId":"perm","request":\#(request)}]},"hasMore":false,"events":[\#(history)]}"#),
                ]
            default:
                return [reply("{}")]
            }
        }
        let hub = AcpmuxHub()
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        let store = AgentChatStore(source: hub.source(sessionID: "s1", summary: Self.summary))
        // Whichever lands first (the reply or the records sent ahead of it), the ask ends on t1.
        for _ in 0..<2000 where store.turns.count < 2 || store.pendingPermission == nil { await Task.yield() }
        #expect(store.turns.map(\.id) == ["t0", "t1"])
        #expect(store.pendingPermission?.request.id == "perm")
        let asks = store.turns.flatMap(\.items).filter { if case .permission = $0 { true } else { false } }
        #expect(asks.count == 1)
    }

    /// The reply lists an ask whose records come strictly after it (sent with a later
    /// reply): the ask is shown at once, then moves to its turn when its record comes.
    @Test func listedAskWhoseRecordComesAfterTheReplyMovesToItsTurn() async throws {
        let link = MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            let request = #"{"toolCall":{"toolCallId":"c","title":"rm","kind":"execute"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"deny","name":"Deny","kind":"reject_once"}]}"#
            func event(_ record: String) -> Data { Data(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":\#(record)}"#.utf8) }
            switch method {
            case "initialize": return [reply(#"{"protocolVersion":1}"#)]
            case "_acpmux/watch": return [reply(#"{"sessions":[{"sessionId":"s1","name":"Fix","harness":"codex","cwd":"/tmp/w","status":"idle"}]}"#)]
            case "_acpmux/attach":
                let history = Self.turnRecords(0).joined(separator: ",")
                return [reply(#"{"session":{"sessionId":"s1","status":"waiting","pending":[{"permissionId":"perm","request":\#(request)}]},"hasMore":false,"events":[\#(history)]}"#)]
            case "_test/later":
                return [
                    reply("{}"),
                    event(#"{"sessionId":"s1","seq":6,"at":5,"dir":"mux","kind":"user_message","msg":{"text":"next","promptId":"p1","turnId":"t1"}}"#),
                    event(#"{"sessionId":"s1","seq":7,"at":5,"dir":"mux","kind":"turn_started","msg":{"turnId":"t1"}}"#),
                    event(#"{"sessionId":"s1","seq":8,"at":5,"dir":"mux","kind":"permission_request","msg":{"permissionId":"perm","request":\#(request)}}"#),
                ]
            default:
                return [reply("{}")]
            }
        }
        let hub = AcpmuxHub()
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        let store = AgentChatStore(source: hub.source(sessionID: "s1", summary: Self.summary))
        // Shown from the reply's pending list, on the page's last turn for now.
        for _ in 0..<2000 where store.pendingPermission == nil { await Task.yield() }
        #expect(store.turns.map(\.id) == ["t0"])
        _ = try await hub.request("_test/later", .object([:]))
        for _ in 0..<2000 where store.turns.count < 2 || store.pendingPermission == nil { await Task.yield() }
        #expect(store.turns.map(\.id) == ["t0", "t1"])
        #expect(store.pendingPermission?.request.id == "perm")
        let asks = store.turns.map { $0.items.filter { if case .permission = $0 { true } else { false } }.count }
        #expect(asks == [0, 1])
    }
}

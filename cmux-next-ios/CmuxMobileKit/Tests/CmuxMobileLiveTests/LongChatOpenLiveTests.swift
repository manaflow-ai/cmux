import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Opening a long agent chat on the phone (Leo, 2026-10-31: "i literally can't load in most of
/// my chats in ios just cuz my gui chats go so long. just... load it in smarter").
///
/// The phone used to read the newest 2000 records in five 400-record round trips, with no byte
/// cap, before it drew anything: 1.3-4.3 MB on the Mac's long chats, and a page that timed out
/// threw the whole read away. A chat whose newest turn ran longer than that showed nothing at
/// all, since records before any prompt have no turn to go in. The Mac's agent pane opens on
/// one byte-capped page (`maxBytes`, acpmux `daemon_chat_open.rs`) and pages older records as
/// the reader scrolls up; the phone does the same.
@MainActor
@Suite struct LongChatOpenLiveTests {
    /// Every request the fake Mac answered: its method and params.
    final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [(String, [String: Any])] = []
        func append(_ method: String, _ params: [String: Any]) { lock.withLock { seen.append((method, params)) } }
        var all: [(method: String, params: [String: Any])] { lock.withLock { seen.map { (method: $0.0, params: $0.1) } } }
        func count(_ method: String) -> Int { all.filter { $0.method == method }.count }
    }

    static let summary = AgentSessionSummary(id: "s7", name: "Fix", harness: "codex", agentName: "Codex", cwd: "/tmp/w",
                                             workspaceTitle: "w", macName: "mini")

    /// Turn `n` of a chat of finished turns: its five records hold seqs 5n+1...5n+5.
    nonisolated static func turnRecords(_ n: Int) -> [(seq: Int, json: String)] {
        let seq = n * 5 + 1
        return [
            (seq, #"{"sessionId":"s1","seq":\#(seq),"at":1,"dir":"mux","kind":"user_message","msg":{"text":"prompt \#(n)","promptId":"p\#(n)","turnId":"t\#(n)"}}"#),
            (seq + 1, #"{"sessionId":"s1","seq":\#(seq + 1),"at":2,"dir":"mux","kind":"turn_started","msg":{"turnId":"t\#(n)"}}"#),
            (seq + 2, #"{"sessionId":"s1","seq":\#(seq + 2),"at":3,"dir":"in","kind":"agent_message_chunk","msg":{"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"answer "}}}}}"#),
            (seq + 3, #"{"sessionId":"s1","seq":\#(seq + 3),"at":3,"dir":"in","kind":"agent_message_chunk","msg":{"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\#(n)"}}}}}"#),
            (seq + 4, #"{"sessionId":"s1","seq":\#(seq + 4),"at":4,"dir":"mux","kind":"turn_result","msg":{"status":"completed","turnId":"t\#(n)"}}"#),
        ]
    }

    /// A fake acpmux over `log` (records oldest first, by seq). `_acpmux/attach` and
    /// `_acpmux/events` answer the newest `limit` records before `beforeSeq` (the log's end when
    /// none), filtered to `user_message` when `kinds` asks for only that; `hasMore` says older
    /// ones exist. `maxBytes` is honoured as acpmux does (whole records, at least one).
    /// `pageLimit`: the most records any page holds, whatever the request's `limit` (pages that
    /// start inside a turn).
    nonisolated static func fakeAcpmux(_ log: [(seq: Int, json: String)], _ requests: Requests, pageLimit: Int = .max,
                                   emptyOlderPageOnce: Bool = false) -> MockMacLink {
        MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            let params = object["params"] as? [String: Any] ?? [:]
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            func page() -> String {
                let before = (params["beforeSeq"] as? NSNumber)?.intValue ?? Int.max
                let limit = min((params["limit"] as? NSNumber)?.intValue ?? 400, pageLimit)
                let maxBytes = (params["maxBytes"] as? NSNumber)?.intValue ?? Int.max
                let kinds = params["kinds"] as? [String] ?? []
                let promptsOnly = kinds == ["user_message"]
                let eligible = log.filter { $0.seq < before && (!promptsOnly || $0.json.contains(#""kind":"user_message""#)) }
                var picked: [(seq: Int, json: String)] = []
                var bytes = 0
                for record in eligible.reversed() {
                    guard picked.count < limit else { break }
                    if !picked.isEmpty, bytes + record.json.utf8.count > maxBytes { break }
                    bytes += record.json.utf8.count
                    picked.insert(record, at: 0)
                }
                let more = eligible.count > picked.count
                return #""hasMore":\#(more),"events":[\#(picked.map(\.json).joined(separator: ","))]"#
            }
            switch method {
            case "initialize": return [reply(#"{"protocolVersion":1}"#)]
            case "_acpmux/watch": return [reply(#"{"sessions":[{"sessionId":"s1","name":"Fix","harness":"codex","cwd":"/tmp/w","status":"idle"}]}"#)]
            case "_acpmux/attach":
                requests.append(method, params)
                return [reply(#"{"session":{"sessionId":"s1","status":"idle","pending":[]},\#(page())}"#)]
            case "_acpmux/events":
                requests.append(method, params)
                if emptyOlderPageOnce, requests.count("_acpmux/events") == 1,
                   params["beforeSeq"] != nil {
                    return [reply(#"{"events":[],"hasMore":true}"#)]
                }
                return [reply("{\(page())}")]
            default:
                return [reply("{}")]
            }
        }
    }

    static func waitUntil(seconds: Int = 10, _ done: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !done(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5)) // test: polls the condition until a deadline
        }
    }

    static func open(_ log: [(seq: Int, json: String)], _ requests: Requests, pageLimit: Int = .max,
                     emptyOlderPageOnce: Bool = false) async throws -> (AcpmuxHub, AgentChatStore) {
        let hub = AcpmuxHub()
        await hub.bind(try await fakeAcpmux(log, requests, pageLimit: pageLimit,
                                            emptyOlderPageOnce: emptyOlderPageOnce).openChannel(service: "acpmux", args: [:]))
        let store = AgentChatStore(source: hub.source(sessionID: "s1", summary: summary))
        return (hub, store)
    }

    /// A long chat opens on one byte-capped read of its newest records: no pages of older
    /// history before the first draw.
    @Test func longChatOpensOnOneBoundedRead() async throws {
        let requests = Requests()
        let log = (0..<1000).flatMap(Self.turnRecords)
        let (hub, store) = try await Self.open(log, requests)
        _ = hub
        await Self.waitUntil { store.turns.last?.id == "t999" }
        // Let any further page reads of the open land before counting them.
        try await Task.sleep(for: .milliseconds(200))

        #expect(store.turns.last?.id == "t999")
        #expect(store.hasEarlierHistory)
        #expect(requests.count("_acpmux/attach") == 1)
        let attach = requests.all.first { $0.method == "_acpmux/attach" }?.params
        #expect((attach?["maxBytes"] as? NSNumber)?.intValue == 128 * 1024,
                "the open read has no byte cap: \(attach ?? [:])")
        #expect(requests.count("_acpmux/events") == 0,
                "the open read older pages before drawing: \(requests.all.map(\.method))")
    }

    /// A newest page that holds no prompt (one turn longer than the page: a coordinator's
    /// long run) still shows that turn: its prompt is read on its own, not every record
    /// between it and the page. Before, the records had no turn to go in and the chat
    /// opened empty.
    @Test func newestPageWithNoPromptShowsItsTurn() async throws {
        let requests = Requests()
        let prompt = (seq: 1, json: #"{"sessionId":"s1","seq":1,"at":1,"dir":"mux","kind":"user_message","msg":{"text":"keep going","promptId":"p0","turnId":"t0"}}"#)
        let chunks = (2...3000).map { seq in
            (seq: seq, json: #"{"sessionId":"s1","seq":\#(seq),"at":3,"dir":"in","kind":"agent_message_chunk","msg":{"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"w\#(seq) "}}}}}"#)
        }
        let (hub, store) = try await Self.open([prompt] + chunks, requests)
        _ = hub
        await Self.waitUntil { store.turns.first?.id == "t0" }

        #expect(store.turns.map(\.id) == ["t0"])
        #expect(store.turns.first?.prompt == "keep going")
        // The newest words are there; the read stayed small (the attach, then the prompt alone).
        let text = store.turns.first?.items.compactMap { item -> String? in
            if case .message(_, let markdown) = item { markdown } else { nil }
        }.joined() ?? ""
        #expect(text.hasSuffix("w3000 "))
        #expect(requests.count("_acpmux/attach") == 1)
        let reads = requests.all.filter { $0.method == "_acpmux/events" }
        #expect(reads.count == 1)
        #expect(reads.first?.params["kinds"] as? [String] == ["user_message"])
    }

    /// Scrolling up reads the page before the oldest turn shown and puts whole turns in front,
    /// in order and drawn in place. Pages that start inside a turn are cut at their first
    /// prompt: the part before it comes, whole, with the page that holds its prompt.
    @Test func scrollingUpPutsWholeOlderTurnsInFront() async throws {
        let requests = Requests()
        let log = (0..<1000).flatMap(Self.turnRecords)
        // 398 records a page: each starts two records into a turn.
        let (hub, store) = try await Self.open(log, requests, pageLimit: 398)
        _ = hub
        await Self.waitUntil { store.turns.last?.id == "t999" }
        let opened = store.turns.map(\.id)
        // The open page starts inside turn 920: its first whole turn is 921.
        #expect(opened.first == "t921")

        store.loadEarlier()
        #expect(store.isLoadingEarlier)
        await Self.waitUntil { store.turns.count > opened.count }

        let ids = store.turns.map(\.id)
        #expect(ids == (1000 - ids.count..<1000).map { "t\($0)" }, "turns missing, repeated or out of order: \(ids.prefix(4))")
        #expect(ids.first == "t842")
        // Turn 920, split across the two reads, is whole.
        let split = store.turns.first { $0.id == "t920" }
        let answer = split?.items.compactMap { item -> String? in
            if case .message(_, let markdown) = item { markdown } else { nil }
        }.joined()
        #expect(answer == "answer 920")
        #expect(split?.status == .completed)
        #expect(store.isReplayed("t842"))
        #expect(store.hasEarlierHistory)
        #expect(!store.isLoadingEarlier)
        let older = requests.all.last
        #expect(older?.method == "_acpmux/events")
        #expect((older?.params["maxBytes"] as? NSNumber)?.intValue == 256 * 1024)
        #expect((older?.params["beforeSeq"] as? NSNumber)?.intValue == 921 * 5 + 1)
    }

    /// A malformed or transient empty _acpmux/events page with hasMore:true
    /// is a failed read, not proof that the chat has reached its first turn.
    @Test func anEmptyOlderPageWithHasMoreKeepsHistoryRetryable() async throws {
        let requests = Requests()
        let log = (0..<100).flatMap(Self.turnRecords)
        let (hub, store) = try await Self.open(log, requests, pageLimit: 398, emptyOlderPageOnce: true)
        _ = hub
        await Self.waitUntil { store.turns.last?.id == "t99" }
        #expect(store.hasEarlierHistory)
        let before = store.turns.map(\.id)

        store.loadEarlier()
        await Self.waitUntil { !store.isLoadingEarlier }
        #expect(store.hasEarlierHistory, "an empty page with hasMore erased the old-history cursor")
        #expect(store.turns.map(\.id) == before)

        // The same cursor succeeds when the transient bad page is gone.
        store.loadEarlier()
        await Self.waitUntil { store.turns.first?.id == "t0" }
        #expect(store.turns.map(\.id) == (0..<100).map { "t\($0)" })
        #expect(!store.hasEarlierHistory)
        #expect(requests.count("_acpmux/events") >= 2)
    }

    /// Scrolling to the start: the last page says nothing older remains.
    @Test func scrollingToTheStartEndsEarlierHistory() async throws {
        let requests = Requests()
        let log = (0..<100).flatMap(Self.turnRecords)
        let (hub, store) = try await Self.open(log, requests, pageLimit: 398)
        _ = hub
        await Self.waitUntil { store.turns.last?.id == "t99" }
        #expect(store.hasEarlierHistory)
        store.loadEarlier()
        await Self.waitUntil { store.turns.first?.id == "t0" }
        #expect(store.turns.map(\.id) == (0..<100).map { "t\($0)" })
        #expect(!store.hasEarlierHistory)
        let reads = requests.count("_acpmux/events")
        store.loadEarlier()
        try await Task.sleep(for: .milliseconds(100))
        #expect(requests.count("_acpmux/events") == reads, "read again past the start")
    }
}

import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// A reattach catches up from the last record shown to the log's end with no gap, however
/// it goes: a page that fails, a lag that lands while the catch-up runs, and a session state
/// that is older than the pages read after it.
@MainActor
@Suite struct ReattachCatchUpLiveTests {
    typealias Chat = ChatOpenSnapshotLiveTests

    /// How many times each method was called, and the `afterSeq` of every attach.
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        private var attachAfter: [Int] = []
        /// Counts a call and returns its number (1 for the first).
        func next(_ key: String) -> Int {
            lock.withLock {
                counts[key, default: 0] += 1
                return counts[key]!
            }
        }
        func attached(after: Int) { lock.withLock { attachAfter.append(after) } }
        var attaches: [Int] { lock.withLock { attachAfter } }
    }

    /// Every record of turns `0..<turns`: record `i` has seq `i + 1` (turn n holds 5n+1...5n+5).
    nonisolated static func log(turns: Int) -> [String] { (0..<turns).flatMap(Chat.turnRecords) }

    /// The records after `after`, at most `limit`, and whether more come after them.
    nonisolated static func page(_ log: [String], after: Int, limit: Int = 5, end: Int? = nil) -> (String, Bool) {
        let last = min(end ?? log.count, log.count)
        let from = min(after, last)
        let to = min(from + limit, last)
        return (log[from..<to].joined(separator: ","), to < last)
    }

    nonisolated static func reply(_ id: String, _ result: String) -> Data {
        Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8)
    }

    nonisolated static func live(_ record: String) -> Data {
        Data(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":\#(record)}"#.utf8)
    }

    nonisolated static let lagged = Data(#"{"jsonrpc":"2.0","method":"_acpmux/lagged","params":{}}"#.utf8)

    /// A fake acpmux over `log`: the first attach gets the first 40 turns at once; `reattach`
    /// answers every attach with `afterSeq` and `events` the `_acpmux/events` pages after one.
    nonisolated static func fake(
        _ calls: Calls,
        log: [String],
        reattach: @escaping @Sendable (_ id: String, _ after: Int, _ n: Int) -> [Data],
        events: @escaping @Sendable (_ id: String, _ after: Int, _ n: Int) -> [Data]
    ) -> MockMacLink {
        MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            let params = object["params"] as? [String: Any]
            let after = (params?["afterSeq"] as? NSNumber)?.intValue ?? 0
            switch method {
            case "initialize": return [reply(id, #"{"protocolVersion":1}"#)]
            case "_acpmux/watch":
                return [reply(id, #"{"sessions":[{"sessionId":"s1","name":"Fix","harness":"codex","cwd":"/tmp/w","status":"idle"}]}"#)]
            case "_acpmux/attach":
                calls.attached(after: after)
                if after > 0 { return reattach(id, after, calls.next("reattach")) }
                let history = log.prefix(Chat.turns * 5).joined(separator: ",")
                return [reply(id, #"{"session":{"sessionId":"s1","status":"idle","pending":[]},"hasMore":false,"lastSeq":\#(Chat.turns * 5),"events":[\#(history)]}"#)]
            case "_acpmux/events":
                return events(id, after, calls.next("events"))
            default:
                return [reply(id, "{}")]
            }
        }
    }

    /// Opens the chat on the first 40 turns, then drops the link and binds it again.
    /// The source holds its hub weakly: a test keeps the hub until it ends.
    static func openThenReconnect(_ link: MockMacLink) async throws -> (AcpmuxHub, AgentChatStore) {
        let hub = AcpmuxHub()
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        let source = hub.source(sessionID: "s1", summary: Chat.summary)
        let store = AgentChatStore(source: source)
        await waitUntil { store.turns.count == Chat.turns }
        #expect(store.turns.count == Chat.turns)
        await hub.bind(nil)
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        return (hub, store)
    }

    /// Waits (on the clock: a retry sleeps) until `done`, for at most 10 s.
    static func waitUntil(_ done: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !done(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Turn n's answer as the chat shows it.
    static func answer(_ store: AgentChatStore, _ n: Int) -> String? {
        guard let turn = store.turns.first(where: { $0.id == "t\(n)" }) else { return nil }
        return turn.items.compactMap { if case .message(_, let markdown) = $0 { markdown } else { nil } }.joined()
    }

    /// A page fails partway through the catch-up while a newer live record waits. The chat
    /// used to apply that record anyway, moving `lastSeq` past the rest of the gap for good.
    /// Now it applies what it read up to its last record, keeps the live one back, and tries
    /// again from there.
    @Test func aFailedPageIsReadAgainBeforeNewerRecords() async throws {
        let calls = Calls()
        let log = Self.log(turns: Chat.turns + 4)
        let link = Self.fake(calls, log: log, reattach: { id, after, n in
            let (records, more) = Self.page(log, after: after)
            var frames = [Self.reply(id, #"{"session":{"sessionId":"s1","status":"idle","pending":[]},"hasMore":\#(more),"events":[\#(records)]}"#)]
            // While the first catch-up runs, turn 43 starts live.
            if n == 1 { frames.append(Self.live(log[(Chat.turns + 3) * 5])) }
            return frames
        }, events: { id, after, n in
            // The first page after the attach reply fails.
            if n == 1 { return [Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"page timed out"}}"#.utf8)] }
            let (records, more) = Self.page(log, after: after)
            return [Self.reply(id, #"{"hasMore":\#(more),"events":[\#(records)]}"#)]
        })
        let (hub, store) = try await Self.openThenReconnect(link)
        defer { withExtendedLifetime(hub) {} }
        let last = Chat.turns + 3
        await Self.waitUntil { store.turns.last?.id == "t\(last)" && store.turns.last?.status == .completed }

        #expect(store.turns.map(\.id) == (0...last).map { "t\($0)" })
        for n in Chat.turns...last {
            #expect(Self.answer(store, n) == "answer \(n)", "turn \(n)")
        }
        // Read again from the last record applied, not from the live one.
        #expect(calls.attaches.prefix(3) == [0, Chat.turns * 5, (Chat.turns + 1) * 5])
    }

    /// The Mac drops a record (`_acpmux/lagged`) while the catch-up is still reading, and a
    /// newer live record is held. The chat used to apply the held record first and refill
    /// after it, so the dropped one was never read. Now the refill reads on from the last
    /// record of the catch-up before anything held is applied.
    @Test func aLagDuringTheCatchUpRefillsBeforeHeldRecords() async throws {
        let calls = Calls()
        let log = Self.log(turns: Chat.turns + 2)
        let first = Chat.turns * 5 // the last seq shown before the reconnect
        let link = Self.fake(calls, log: log, reattach: { id, after, n in
            if n == 1 {
                // The first catch-up reads one record, then pages on; meanwhile the Mac drops
                // the record after its end (seq first + 3) and sends the one after that live.
                let (records, _) = Self.page(log, after: after, limit: 1)
                return [
                    Self.reply(id, #"{"session":{"sessionId":"s1","status":"running","pending":[]},"hasMore":true,"events":[\#(records)]}"#),
                    Self.lagged,
                    Self.live(log[first + 3]),
                ]
            }
            let (records, more) = Self.page(log, after: after, limit: 400)
            return [Self.reply(id, #"{"session":{"sessionId":"s1","status":"idle","pending":[]},"hasMore":\#(more),"events":[\#(records)]}"#)]
        }, events: { id, after, n in
            // The first catch-up's log ends at seq first + 2 (what was written by then).
            let (records, more) = n == 1 ? Self.page(log, after: after, limit: 1, end: first + 2) : Self.page(log, after: after, limit: 400)
            return [Self.reply(id, #"{"hasMore":\#(more),"events":[\#(records)]}"#)]
        })
        let (hub, store) = try await Self.openThenReconnect(link)
        defer { withExtendedLifetime(hub) {} }
        let last = Chat.turns + 1
        await Self.waitUntil { store.turns.last?.id == "t\(last)" && store.turns.last?.status == .completed }

        #expect(store.turns.map(\.id) == (0...last).map { "t\($0)" })
        // Seq first + 3 is the turn's first answer chunk ("answer "), the held one its second.
        #expect(Self.answer(store, Chat.turns) == "answer \(Chat.turns)")
        #expect(Self.answer(store, last) == "answer \(last)")
        #expect(calls.attaches.prefix(3) == [0, first, first + 2])
    }

    /// A long catch-up reads pages written after the attach reply: here the turn ends in a
    /// later page. The reply's session state (running) is as of its `lastSeq`, so it goes in
    /// there, not after every page: the chat used to end the catch-up showing the finished
    /// turn's chat as running.
    @Test func theAttachStateLandsAtItsOwnSeq() async throws {
        let calls = Calls()
        let log = Self.log(turns: Chat.turns + 1)
        let first = Chat.turns * 5
        let link = Self.fake(calls, log: log, reattach: { id, after, _ in
            // At the reply the turn had started (seq first + 2): status running.
            let (records, _) = Self.page(log, after: after, limit: 2)
            return [Self.reply(id, #"{"session":{"sessionId":"s1","status":"running","pending":[]},"hasMore":true,"lastSeq":\#(first + 2),"events":[\#(records)]}"#)]
        }, events: { id, after, _ in
            // The rest, through the turn's result, was written after the reply.
            let (records, more) = Self.page(log, after: after, limit: 400)
            return [Self.reply(id, #"{"hasMore":\#(more),"events":[\#(records)]}"#)]
        })
        let (hub, store) = try await Self.openThenReconnect(link)
        defer { withExtendedLifetime(hub) {} }
        let last = Chat.turns
        await Self.waitUntil { store.turns.last?.id == "t\(last)" && store.turns.last?.status == .completed }
        // Anything the catch-up still sends after the turn's end lands by now.
        for _ in 0..<200 { await Task.yield() }

        #expect(store.turns.last?.status == .completed)
        #expect(store.summary.status == .idle)
    }

    /// A chat nobody keeps any more goes away while its attach waits on the Mac, and the
    /// attach stops: the attach task used to hold the source until the reply came, which on
    /// a link that stopped answering was never.
    @Test func aChatNobodyKeepsGoesAwayWhileItsAttachWaits() async throws {
        let calls = Calls()
        // The Mac never answers an attach.
        let link = MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            switch method {
            case "initialize": return [Self.reply(id, #"{"protocolVersion":1}"#)]
            case "_acpmux/watch":
                return [Self.reply(id, #"{"sessions":[{"sessionId":"s1","name":"Fix","harness":"codex","cwd":"/tmp/w","status":"idle"}]}"#)]
            case "_acpmux/attach":
                calls.attached(after: 0)
                return []
            default:
                return [Self.reply(id, "{}")]
            }
        }
        let hub = AcpmuxHub()
        defer { withExtendedLifetime(hub) {} }
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        weak var released: AcpmuxSessionSource?
        do {
            let source = hub.source(sessionID: "s1", summary: Chat.summary)
            released = source
            await Self.waitUntil { calls.attaches.count == 1 }
            #expect(calls.attaches.count == 1)
        }
        await Self.waitUntil { released == nil }
        #expect(released == nil)
    }
}

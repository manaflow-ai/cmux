import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// A reattach after a long time away reads tail-first: the newest page (as an open reads it)
/// shows at once, at a cost that does not grow with what was missed, and the records before it
/// fill in afterwards, in bounded pages, in order, each once, while live records go on. A gap
/// that fits one page reads as it always did, and a Mac that pages only forward still catches up.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5))) struct TailFirstReattachLiveTests {
    typealias Chat = ChatOpenSnapshotLiveTests

    /// A fake acpmux over a log of `Chat.turnRecords` turns that pages as acpmux does
    /// (cmux-tui acpmux `_acpmux/attach` and `_acpmux/events`, hub/paging.rs): `limit` records and
    /// `maxBytes` of whole records (1 MiB when unnamed), at least one; `afterSeq` alone pages
    /// forward; otherwise the page is the newest records with `afterSeq < seq < beforeSeq`.
    /// `forwardOnly`: a Mac that reads every `afterSeq` forward, whatever `beforeSeq` says.
    final class Fake: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [(seq: Int, json: String)]
        private var end: Int
        let forwardOnly: Bool
        private var failGap = false
        private var liveWithFirstGapPage: [(seq: Int, json: String)] = []
        private var attachParams: [[String: Any]] = []
        private var eventsCalls = 0
        private var gapPages = 0
        private var sent = 0
        private var growTurn: Int?
        private var failNextForward = false

        init(turns: Range<Int>, skipping: Set<Int> = [], visibleThrough: Int, forwardOnly: Bool = false) {
            log = turns.filter { !skipping.contains($0) }.flatMap { n in
                Chat.turnRecords(n).enumerated().map { (seq: n * 5 + 1 + $0.offset, json: $0.element) }
            }
            end = visibleThrough
            self.forwardOnly = forwardOnly
        }

        /// The Mac has written through turn `turn` (its last seq).
        func write(through turn: Int) { lock.withLock { end = turn * 5 + 5 } }
        func failGapPages(_ fail: Bool) { lock.withLock { failGap = fail } }
        /// Turns written (and sent live) while the first gap page is read.
        func liveDuringFill(_ turns: Range<Int>) {
            lock.withLock {
                liveWithFirstGapPage = turns.flatMap { n in Chat.turnRecords(n).enumerated().map { (seq: n * 5 + 1 + $0.offset, json: $0.element) } }
            }
        }
        /// The Mac writes through turn `turn` while the first forward read (no `maxBytes`) is served:
        /// that read is one record long (`hasMore`), and the next forward read fails once.
        func growAndFailForwardOnce(through turn: Int) { lock.withLock { growTurn = turn } }
        var attaches: [[String: Any]] { lock.withLock { attachParams } }
        var gapPageCount: Int { lock.withLock { gapPages } }
        var eventsCallCount: Int { lock.withLock { eventsCalls } }
        /// Records sent in replies (live ones not counted).
        var recordsSent: Int { lock.withLock { sent } }
        func resetCounts() { lock.withLock { (sent, eventsCalls, gapPages) = (0, 0, 0) } }

        private func page(_ params: [String: Any], limit limitOverride: Int? = nil) -> (String, Bool) {
            let limit = max(limitOverride ?? (params["limit"] as? NSNumber)?.intValue ?? 400, 1)
            let maxBytes = (params["maxBytes"] as? NSNumber)?.intValue ?? 1_048_576
            let after = (params["afterSeq"] as? NSNumber)?.intValue
            let before = (params["beforeSeq"] as? NSNumber)?.intValue
            let shown = log.filter { $0.seq <= end }
            var picked: [String] = []
            var bytes = 0
            func full(_ json: String) -> Bool {
                picked.count == limit || (!picked.isEmpty && bytes + json.utf8.count > maxBytes)
            }
            var more = false
            if let after, before == nil || forwardOnly {
                for record in shown where record.seq > after {
                    if full(record.json) { more = true; break }
                    bytes += record.json.utf8.count
                    picked.append(record.json)
                }
            } else {
                for record in shown.reversed() where record.seq > (after ?? 0) && record.seq < (before ?? .max) {
                    if full(record.json) { more = true; break }
                    bytes += record.json.utf8.count
                    picked.append(record.json)
                }
                picked.reverse()
            }
            sent += picked.count
            return (picked.joined(separator: ","), more)
        }

        func link() -> MockMacLink {
            MockMacLink { [self] _, data in
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let method = object["method"] as? String else { return [] }
                let id = object["id"].map { "\($0)" } ?? "null"
                let params = object["params"] as? [String: Any] ?? [:]
                func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
                return lock.withLock { () -> [Data] in
                    switch method {
                    case "initialize": return [reply(#"{"protocolVersion":1}"#)]
                    case "_acpmux/watch":
                        return [reply(#"{"sessions":[{"sessionId":"s1","name":"Fix","harness":"codex","cwd":"/tmp/w","status":"idle"}]}"#)]
                    case "_acpmux/attach":
                        attachParams.append(params)
                        let (records, more) = page(params)
                        return [reply(#"{"session":{"sessionId":"s1","status":"idle","pending":[]},"lastSeq":\#(end),"hasMore":\#(more),"events":[\#(records)]}"#)]
                    case "_acpmux/events":
                        eventsCalls += 1
                        // The gap's pages are the byte-capped forward reads.
                        let gapPage = params["maxBytes"] != nil
                        if gapPage {
                            gapPages += 1
                            if failGap {
                                return [Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"page timed out"}}"#.utf8)]
                            }
                        }
                        var limitOverride: Int?
                        if !gapPage {
                            if let turn = growTurn {
                                growTurn = nil
                                failNextForward = true
                                end = turn * 5 + 5
                                limitOverride = 1
                            } else if failNextForward {
                                failNextForward = false
                                return [Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"page timed out"}}"#.utf8)]
                            }
                        }
                        let (records, more) = page(params, limit: limitOverride)
                        var frames = [reply(#"{"hasMore":\#(more),"events":[\#(records)]}"#)]
                        if gapPage, !liveWithFirstGapPage.isEmpty {
                            let live = liveWithFirstGapPage
                            liveWithFirstGapPage = []
                            log += live
                            end = live.last?.seq ?? end
                            frames += live.map { Data(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":\#($0.json)}"#.utf8) }
                        }
                        return frames
                    default:
                        return [reply("{}")]
                    }
                }
            }
        }
    }

    /// The chat opened on turns 0..<40, then the link dropped while the Mac wrote through
    /// `missedThrough`, and came back. A test keeps the hub until it ends.
    static func reconnect(_ fake: Fake, missedThrough: Int) async throws -> (AcpmuxHub, AcpmuxSessionSource, AgentChatStore, MockMacLink) {
        let link = fake.link()
        let hub = AcpmuxHub()
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        let source = hub.source(sessionID: "s1", summary: Chat.summary)
        let store = AgentChatStore(source: source)
        await Self.waitUntil { store.turns.count == Chat.turns }
        #expect(store.turns.map(\.id) == ids(0..<Chat.turns))
        await hub.bind(nil)
        fake.write(through: missedThrough)
        fake.resetCounts()
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        return (hub, source, store, link)
    }

    /// Each test reads hundreds of turns over the fake link; with the whole kit running in
    /// parallel on one runner that takes several seconds, so a wait has no deadline of its own
    /// and ends when it is met; the suite's time limit (5 min: it runs its tests one at a time,
    /// for the same reason) bounds a hang.
    static func waitUntil(_ done: () -> Bool) async {
        await LongChatOpenLiveTests.waitUntil(done)
    }

    static func ids(_ turns: some Sequence<Int>) -> [String] { turns.map { "t\($0)" } }

    static func shows(_ store: AgentChatStore, _ turn: Int) -> Bool {
        store.turns.last?.id == "t\(turn)" && store.turns.last?.status == .completed
    }

    /// 300 turns missed (1,500 records): the reattach reads the newest page (400 records, 80
    /// turns) and one empty read after it, and shows them with the gap before them still open.
    @Test func aLargeGapShowsTheNewestRecordsFirst() async throws {
        let last = Chat.turns + 299
        let fake = Fake(turns: 0..<(last + 1), visibleThrough: Chat.turns * 5)
        fake.failGapPages(true)
        let (hub, source, store, link) = try await Self.reconnect(fake, missedThrough: last)
        defer { withExtendedLifetime((hub, link)) {} }
        await Self.waitUntil { Self.shows(store, last) && fake.gapPageCount > 0 }

        // The chat had, then the newest 80 turns; the 220 between are still on the Mac.
        #expect(store.turns.map(\.id) == Self.ids(0..<Chat.turns) + Self.ids((last - 79)...last))
        #expect(store.isFillingGap)
        #expect(store.gapBeforeTurnID == "t\(last - 79)")
        #expect(source.gapFill == AcpmuxSessionSource.GapFill(cursor: Chat.turns * 5, end: (last - 79) * 5 + 1))
        // One bounded page for the newest records, whatever was missed.
        let reattach = try #require(fake.attaches.last)
        #expect((reattach["afterSeq"] as? NSNumber)?.intValue == Chat.turns * 5)
        #expect(reattach["beforeSeq"] != nil)
        #expect((reattach["maxBytes"] as? NSNumber)?.intValue == AcpmuxSessionSource.openBytes)
        #expect(fake.recordsSent == 400)

        // The link comes back again: the gap fills from where it stopped, and nothing repeats.
        fake.failGapPages(false)
        await hub.bind(nil)
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        await Self.waitUntil { !store.isFillingGap }
        #expect(!store.isFillingGap)
        #expect(store.turns.map(\.id) == Self.ids(0...last))
        #expect(source.gapFill == nil)
    }

    /// The gap's pages go in where it is, oldest first: every turn once, in order, with its
    /// answer, and a later reader of the source gets the same chat.
    @Test func theGapFillsCompletelyInOrder() async throws {
        let last = Chat.turns + 299
        let fake = Fake(turns: 0..<(last + 1), visibleThrough: Chat.turns * 5)
        let (hub, source, store, link) = try await Self.reconnect(fake, missedThrough: last)
        defer { withExtendedLifetime((hub, link)) {} }
        await Self.waitUntil { Self.shows(store, last) && !store.isFillingGap && store.turns.count == last + 1 }

        #expect(store.turns.map(\.id) == Self.ids(0...last))
        for turn in store.turns {
            #expect(ReattachCatchUpLiveTests.answer(store, Int(turn.id.dropFirst()) ?? -1) == "answer \(turn.id.dropFirst())", "turn \(turn.id)")
            #expect(turn.status == .completed, "turn \(turn.id)")
        }
        // Bounded pages: 1,100 records in the gap, 400 a page at most.
        #expect(fake.gapPageCount >= 3)
        #expect(source.gapFill == nil)
        #expect(store.gapBeforeTurnID == nil)
        // The chat's turns are drawn in place, as history.
        #expect(store.isReplayed("t\(Chat.turns + 10)"))

        let second = AgentChatStore(source: source)
        await Self.waitUntil { second.turns.count == last + 1 }
        #expect(second.turns.map(\.id) == Self.ids(0...last))
        #expect(!second.isFillingGap)
    }

    /// Turns the Mac writes while the gap fills arrive live and stay after the newest page;
    /// the gap goes in before them.
    @Test func liveRecordsDuringTheFillAreKept() async throws {
        let last = Chat.turns + 299
        let fake = Fake(turns: 0..<(last + 1), visibleThrough: Chat.turns * 5)
        fake.liveDuringFill((last + 1)..<(last + 3))
        let (hub, _, store, link) = try await Self.reconnect(fake, missedThrough: last)
        defer { withExtendedLifetime((hub, link)) {} }
        let newest = last + 2
        await Self.waitUntil { Self.shows(store, newest) && !store.isFillingGap && store.turns.count == newest + 1 }

        #expect(store.turns.map(\.id) == Self.ids(0...newest))
        #expect(ReattachCatchUpLiveTests.answer(store, newest) == "answer \(newest)")
    }

    /// The gap's records reach the chat but not the phone's kept copy: after a tail-first
    /// reattach the kept copy starts again at the newest page's first prompt, with older records
    /// on the Mac, so a relaunch never shows the turns before the gap joined to the newest ones
    /// with nothing between (scrolling up reads the gap as older pages).
    @Test func aGapRestartsTheKeptCopyAtTheNewestRecords() async throws {
        typealias Kept = AgentKeptTranscriptTests
        let last = Chat.turns + 299
        let fake = Fake(turns: 0..<(last + 1), visibleThrough: Chat.turns * 5)
        fake.failGapPages(true)
        let cache = Kept.cache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let link = fake.link()
        let hub = Kept.hub(cache)
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        let source = hub.source(sessionID: "s1", summary: Kept.summary)
        let store = AgentChatStore(source: source)
        await Self.waitUntil { store.turns.count == Chat.turns }
        #expect(store.turns.map(\.id) == Self.ids(0..<Chat.turns))

        await hub.bind(nil)
        fake.write(through: last)
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        await Self.waitUntil { Self.shows(store, last) && fake.gapPageCount > 0 }
        #expect(store.isFillingGap)

        // The link drops with the gap still open: the kept copy is saved as it stands.
        await hub.bind(nil)
        cache.flush()
        let key = try #require(AgentTranscriptCache.key(accountID: "acct", macID: "mac1", tabID: "s7"))
        let entry = try #require(cache.cached(key))
        #expect(entry.earlier)
        #expect(entry.records.first?["msg"]?["turnId"]?.stringValue == "t\(last - 79)")
        #expect(entry.records.allSatisfy { Int($0["seq"]?.numberValue ?? 0) > (last - 79) * 5 })
        #expect(entry.lastSeq == last * 5 + 5)
    }

    /// A gap that fits one page: the reattach's one page is everything missed, applied as one
    /// batch, with no gap and no other read.
    @Test func aSmallGapReadsAsBefore() async throws {
        let last = Chat.turns + 2
        let fake = Fake(turns: 0..<(last + 1), visibleThrough: Chat.turns * 5)
        let (hub, source, store, link) = try await Self.reconnect(fake, missedThrough: last)
        defer { withExtendedLifetime((hub, link)) {} }
        await Self.waitUntil { Self.shows(store, last) }

        #expect(store.turns.map(\.id) == Self.ids(0...last))
        #expect(!store.isFillingGap)
        #expect(source.gapFill == nil)
        #expect(fake.eventsCallCount == 0)
        #expect(fake.recordsSent == 15)
    }

    /// A Mac that reads every `afterSeq` forward (it ignores `beforeSeq`): the reattach pages
    /// forward through the whole gap, as it always did, and opens none. `hole`: the records just
    /// after the last one shown are not in its log (another kind), so its first page does not
    /// start right after it.
    @Test(arguments: [false, true])
    func aMacThatPagesForwardStillCatchesUp(_ hole: Bool) async throws {
        let last = Chat.turns + 299
        let fake = Fake(turns: 0..<(last + 1), skipping: hole ? [Chat.turns] : [], visibleThrough: Chat.turns * 5,
                        forwardOnly: true)
        let (hub, source, store, link) = try await Self.reconnect(fake, missedThrough: last)
        defer { withExtendedLifetime((hub, link)) {} }
        await Self.waitUntil { Self.shows(store, last) }

        let missed = (Chat.turns...last).filter { !hole || $0 != Chat.turns }
        #expect(store.turns.map(\.id) == Self.ids(0..<Chat.turns) + Self.ids(missed))
        #expect(!store.isFillingGap)
        #expect(source.gapFill == nil)
        #expect(fake.gapPageCount == 0)
    }

    /// Two turns are written after the attach reply's `lastSeq`, and the forward read after the
    /// newest page returns one of them with `hasMore`; the next forward read fails. Nothing of
    /// that read is applied (`lastSeq` stays), and the retry reads tail-first again: the chat
    /// ends with every turn once, in order.
    @Test func aForwardPageThatFailsAppliesNothingAndTheRetryReadsTailFirst() async throws {
        let missed = Chat.turns + 299
        let last = missed + 2
        let fake = Fake(turns: 0..<(last + 1), visibleThrough: Chat.turns * 5)
        fake.growAndFailForwardOnce(through: last)
        let (hub, source, store, link) = try await Self.reconnect(fake, missedThrough: missed)
        defer { withExtendedLifetime((hub, link)) {} }
        await Self.waitUntil { Self.shows(store, last) && !store.isFillingGap && store.turns.count == last + 1 }

        #expect(store.turns.map(\.id) == Self.ids(0...last))
        #expect(!store.isFillingGap)
        #expect(source.gapFill == nil)
        // The failed attach and the retry: both read tail-first from the same `lastSeq`.
        let attaches = fake.attaches
        #expect(attaches.count >= 2)
        for attach in attaches.suffix(2) {
            #expect((attach["afterSeq"] as? NSNumber)?.intValue == Chat.turns * 5)
            #expect(attach["beforeSeq"] != nil)
        }
    }
}

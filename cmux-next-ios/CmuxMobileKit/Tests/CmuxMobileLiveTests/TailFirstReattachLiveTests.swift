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
        /// A current Mac: its `initialize` names its capabilities, and an attach says how far its
        /// page holds (`pageThrough`, acpmux server/requests.rs `page_reaches_end`).
        let current: Bool
        private var methodLog: [String] = []
        private var failGap = false
        private var failNextGap = false
        private var liveWithFirstGapPage: [(seq: Int, json: String)] = []
        private var attachParams: [[String: Any]] = []
        private var eventsCalls = 0
        private var gapPages = 0
        private var sent = 0
        private var growTurn: Int?
        private var failNextForward = false
        private var gapLimit: Int?

        init(turns: Range<Int>, skipping: Set<Int> = [], visibleThrough: Int, forwardOnly: Bool = false, current: Bool = false) {
            self.current = current
            log = turns.filter { !skipping.contains($0) }.flatMap { n in
                Chat.turnRecords(n).enumerated().map { (seq: n * 5 + 1 + $0.offset, json: $0.element) }
            }
            end = visibleThrough
            self.forwardOnly = forwardOnly
        }

        /// The Mac has written through turn `turn` (its last seq).
        func write(through turn: Int) { lock.withLock { end = turn * 5 + 5 } }
        func failGapPages(_ fail: Bool) { lock.withLock { failGap = fail } }
        func failNextGapPage() { lock.withLock { failNextGap = true } }
        /// Each gap page holds at most `limit` records (the gap is read in several pages).
        func gapPagesHold(_ limit: Int) { lock.withLock { gapLimit = limit } }
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
        var methods: [String] { lock.withLock { methodLog } }
        /// Records sent in replies (live ones not counted).
        var recordsSent: Int { lock.withLock { sent } }
        func resetCounts() { lock.withLock { (sent, eventsCalls, gapPages, methodLog) = (0, 0, 0, []) } }

        /// What acpmux's attach says as `pageThrough`: the log's end for a newest page (no
        /// `afterSeq`, or a `beforeSeq` past the end) or a forward page that read to it, else the
        /// page's own newest record.
        private func through(_ params: [String: Any], records: String, more: Bool) -> Int {
            let after = (params["afterSeq"] as? NSNumber)?.intValue
            let before = (params["beforeSeq"] as? NSNumber)?.intValue
            let toEnd = before.map { $0 > end } ?? (after == nil || !more)
            if toEnd && !(forwardOnly && more) { return end }
            let seqs = records.components(separatedBy: "\"seq\":").dropFirst().compactMap { Int($0.prefix { $0.isNumber }) }
            return seqs.max() ?? (after ?? 0)
        }

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
                    methodLog.append(method)
                    switch method {
                    case "initialize" where current:
                        return [reply(#"{"protocolVersion":1,"_meta":{"acpmux":{"capabilities":["elevation-cards-v1"]}}}"#)]
                    case "initialize": return [reply(#"{"protocolVersion":1}"#)]
                    case "_acpmux/watch":
                        return [reply(#"{"sessions":[{"sessionId":"s1","name":"Fix","harness":"codex","cwd":"/tmp/w","status":"idle"}]}"#)]
                    case "_acpmux/attach":
                        attachParams.append(params)
                        let (records, more) = page(params)
                        let pageThrough = current ? #","pageThrough":\#(through(params, records: records, more: more))"# : ""
                        return [reply(#"{"session":{"sessionId":"s1","status":"idle","pending":[]},"lastSeq":\#(end),"hasMore":\#(more)\#(pageThrough),"events":[\#(records)]}"#)]
                    case "_acpmux/events":
                        eventsCalls += 1
                        // The gap's pages are the byte-capped forward reads.
                        let gapPage = params["maxBytes"] != nil
                        if gapPage {
                            gapPages += 1
                            if failGap || failNextGap {
                                failNextGap = false
                                return [Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"page timed out"}}"#.utf8)]
                            }
                        }
                        var limitOverride: Int? = gapPage ? gapLimit : nil
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
    /// `missedThrough`, and came back. `beforeReattach` runs with the link down, just before it
    /// comes back. A test keeps the hub until it ends.
    static func reconnect(
        _ fake: Fake, missedThrough: Int, beforeReattach: (AcpmuxSessionSource) -> Void = { _ in }
    ) async throws -> (AcpmuxHub, AcpmuxSessionSource, AgentChatStore, MockMacLink) {
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
        beforeReattach(source)
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        return (hub, source, store, link)
    }

    /// What a reader of a source got: each `.gapPage` (how many records it had, and `done`),
    /// until its stream ended.
    final class GapPages {
        var pages: [(events: Int, done: Bool)] = []
        var ended = false
        var task: Task<Void, Never>?
    }

    /// Reads `source` as a chat does, keeping the `.gapPage`s it sends.
    static func watchGapPages(_ source: AcpmuxSessionSource) -> GapPages {
        let watch = GapPages()
        let stream = source.events()
        watch.task = Task { @MainActor in
            for await event in stream {
                if case .gapPage(let events, let done) = event { watch.pages.append((events.count, done)) }
            }
            watch.ended = true
        }
        return watch
    }

    /// The coordinator builds a chat's store again when its source resets (`onReset`); so do
    /// these tests.
    final class Rebuilt {
        var store: AgentChatStore?
        var resets = 0
    }

    static func rebuildOnReset(_ source: AcpmuxSessionSource) -> Rebuilt {
        let rebuilt = Rebuilt()
        source.onReset = {
            rebuilt.resets += 1
            rebuilt.store = AgentChatStore(source: source)
        }
        return rebuilt
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

    /// A hole that fits in one page (`bridgeMaxSeqs`): 120 turns missed (600 records). The
    /// reattach reads the newest page (400 records, 80 turns), so 40 turns (200 records) are
    /// missing before it.
    static let narrowMissed = Chat.turns + 119

    /// Leo, 2026-11-17, on the Mac's agent pane after a reconnect (the same class of bug): "THIS
    /// KIND OF RERENDER RESHIFT RE-MOVING EVERYTHING IS UNACCEPTABLE". 300 turns missed (1,500
    /// records): the reattach reads the newest page (400 records, 80 turns) and one empty read
    /// after it. The 220 turns before that page are wider than one page, so they are not read:
    /// the turns the chat had go, and the newest page opens the chat with older history from
    /// scrolling up. It used to read them in pages and draw each above the newest turn.
    @Test func aWideHoleOpensOnTheNewestPageWithNoGapPages() async throws {
        let last = Chat.turns + 299
        let fake = Fake(turns: 0..<(last + 1), visibleThrough: Chat.turns * 5)
        var watch: GapPages?
        var rebuilt: Rebuilt?
        let (hub, source, _, link) = try await Self.reconnect(fake, missedThrough: last) { source in
            watch = Self.watchGapPages(source)
            rebuilt = Self.rebuildOnReset(source)
        }
        defer { withExtendedLifetime((hub, link)) {} }
        let gapPages = try #require(watch)
        let chat = try #require(rebuilt)
        await Self.waitUntil {
            chat.store.map { Self.shows($0, last) && !$0.isLoadingHistory } == true && gapPages.ended
        }
        let store = try #require(chat.store)

        // The newest 80 turns, nothing held from before the hole, and no gap.
        #expect(chat.resets == 1)
        #expect(store.turns.map(\.id) == Self.ids((last - 79)...last))
        #expect(store.hasEarlierHistory)
        #expect(!store.isFillingGap)
        #expect(source.gapFill == nil)
        #expect(gapPages.pages.isEmpty)
        #expect(fake.gapPageCount == 0)
        // One bounded page, whatever was missed: the page read opens the chat, with no read again.
        #expect(fake.attaches.count == 2)
        #expect(fake.recordsSent == 400)

        // Scrolling up reads the turn before it.
        store.loadEarlier()
        await Self.waitUntil { store.turns.first?.id != "t\(last - 79)" }
        #expect(store.turns.last?.id == "t\(last)")
        #expect(store.turns.contains { $0.id == "t\(last - 80)" })
    }

    /// A Mac that reads every `afterSeq` forward (it ignores `beforeSeq`), after a hole far wider
    /// than a page: the reattach reads forward at most `forwardMaxSeqs`, then opens on the newest
    /// page as a first attach, instead of reading everything it missed.
    @Test func aWideHoleOnAMacThatPagesForwardOpensFresh() async throws {
        let last = Chat.turns + 999
        let fake = Fake(turns: 0..<(last + 1), visibleThrough: Chat.turns * 5, forwardOnly: true)
        var rebuilt: Rebuilt?
        let (hub, source, _, link) = try await Self.reconnect(fake, missedThrough: last) { source in
            rebuilt = Self.rebuildOnReset(source)
        }
        defer { withExtendedLifetime((hub, link)) {} }
        let chat = try #require(rebuilt)
        await Self.waitUntil { chat.store.map { Self.shows($0, last) && !$0.isLoadingHistory } == true }
        let store = try #require(chat.store)

        #expect(chat.resets == 1)
        #expect(store.turns.first?.id != "t0")
        #expect(store.hasEarlierHistory)
        #expect(source.gapFill == nil)
        #expect(fake.gapPageCount == 0)
        // The reattach and the first attach after it.
        let attaches = fake.attaches.suffix(2)
        #expect((attaches.first?["afterSeq"] as? NSNumber)?.intValue == Chat.turns * 5)
        #expect(attaches.last?["afterSeq"] == nil)
        // Far fewer than the 5,000 records missed.
        #expect(fake.recordsSent < 2_500)
    }

    /// A hole narrower than one page is read whole, in bounded pages, then goes in once: the
    /// chat gets one `.gapPage` (done) with every record in it, however many reads it took.
    /// Each turn once, in order, with its answer, and a later reader of the source gets the same
    /// chat. It used to send one `.gapPage` per read, each redrawing the turns above the newest.
    @Test func aNarrowHoleIsReadWholeAndGoesInOnce() async throws {
        let last = Self.narrowMissed
        let fake = Fake(turns: 0..<(last + 1), visibleThrough: Chat.turns * 5)
        // 200 records missing, 50 a page: four reads.
        fake.gapPagesHold(50)
        var watch: GapPages?
        let (hub, source, store, link) = try await Self.reconnect(fake, missedThrough: last) { source in
            watch = Self.watchGapPages(source)
        }
        defer { withExtendedLifetime((hub, link)) {} }
        let gapPages = try #require(watch)
        await Self.waitUntil { Self.shows(store, last) && !store.isFillingGap && store.turns.count == last + 1 }

        #expect(store.turns.map(\.id) == Self.ids(0...last))
        for turn in store.turns {
            #expect(ReattachCatchUpLiveTests.answer(store, Int(turn.id.dropFirst()) ?? -1) == "answer \(turn.id.dropFirst())", "turn \(turn.id)")
            #expect(turn.status == .completed, "turn \(turn.id)")
        }
        #expect(fake.gapPageCount >= 4)
        #expect(gapPages.pages.count == 1)
        #expect(gapPages.pages.first?.done == true)
        #expect(source.gapFill == nil)
        #expect(store.gapBeforeTurnID == nil)
        // The chat's turns are drawn in place, as history.
        #expect(store.isReplayed("t\(Chat.turns + 10)"))

        let second = AgentChatStore(source: source)
        await Self.waitUntil { second.turns.count == last + 1 }
        #expect(second.turns.map(\.id) == Self.ids(0...last))
        #expect(!second.isFillingGap)
    }

    /// A narrow hole whose read fails shows none of it, and stays open: the link comes back and
    /// the hole is read again from its start, then goes in once.
    @Test func aNarrowHoleThatFailsIsReadAgainWhole() async throws {
        let last = Self.narrowMissed
        let fake = Fake(turns: 0..<(last + 1), visibleThrough: Chat.turns * 5)
        fake.failGapPages(true)
        let (hub, source, store, link) = try await Self.reconnect(fake, missedThrough: last)
        defer { withExtendedLifetime((hub, link)) {} }
        await Self.waitUntil { Self.shows(store, last) && fake.gapPageCount > 0 }

        // The chat had, then the newest 80 turns; the 40 between are still on the Mac.
        #expect(store.turns.map(\.id) == Self.ids(0..<Chat.turns) + Self.ids((last - 79)...last))
        #expect(store.isFillingGap)
        #expect(store.gapBeforeTurnID == "t\(last - 79)")
        #expect(source.gapFill == AcpmuxSessionSource.GapFill(cursor: Chat.turns * 5, end: (last - 79) * 5 + 1))
        let reattach = try #require(fake.attaches.last)
        #expect((reattach["afterSeq"] as? NSNumber)?.intValue == Chat.turns * 5)
        #expect(reattach["beforeSeq"] != nil)
        #expect((reattach["maxBytes"] as? NSNumber)?.intValue == AcpmuxSessionSource.openBytes)
        #expect(fake.recordsSent == 400)

        fake.failGapPages(false)
        await hub.bind(nil)
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        await Self.waitUntil { !store.isFillingGap }
        #expect(store.turns.map(\.id) == Self.ids(0...last))
        #expect(source.gapFill == nil)
    }

    /// A transient gap-page failure retries on the healthy connection, without waiting for
    /// another attach to restart the fill.
    @Test func aNarrowHoleRetriesAfterOnePageFailure() async throws {
        let last = Self.narrowMissed
        let fake = Fake(turns: 0..<(last + 1), visibleThrough: Chat.turns * 5)
        fake.gapPagesHold(50)
        fake.failNextGapPage()
        let (hub, source, store, link) = try await Self.reconnect(fake, missedThrough: last)
        defer { withExtendedLifetime((hub, link)) {} }

        await Self.waitUntil { Self.shows(store, last) && !store.isFillingGap }
        #expect(store.turns.map(\.id) == Self.ids(0...last))
        #expect(source.gapFill == nil)
        // The open and the reattach (`reconnect`; `resetCounts` keeps attaches), and no third:
        // the failed page retried on its own.
        #expect(fake.attaches.count == 2)
        #expect(fake.gapPageCount >= 5)
    }

    /// Turns the Mac writes while the gap fills arrive live and stay after the newest page;
    /// the gap goes in before them.
    @Test func liveRecordsDuringTheFillAreKept() async throws {
        let last = Self.narrowMissed
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
        let last = Self.narrowMissed
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
    /// forward through a hole within `forwardMaxSeqs`, as it always did, and opens none. `hole`:
    /// the records just after the last one shown are not in its log (another kind), so its first
    /// page does not start right after it.
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
        let missed = Self.narrowMissed
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

    /// A narrow hole (a wide one opens fresh, with no gap to read), its gap pages failing so the
    /// gap stays open. A current Mac (new phone, new Mac): the reattach's newest page says it
    /// reaches the end (`pageThrough` = `lastSeq`), so no `_acpmux/events` read follows it, and the attach went
    /// out with `initialize` and the watch, read from that write. The chat shows the same turns
    /// as against an older Mac.
    @Test func aCurrentMacNeedsNoReadAfterTheNewestPageAndTheAttachRidesWithInitialize() async throws {
        let last = Self.narrowMissed
        let fake = Fake(turns: 0..<(last + 1), visibleThrough: Chat.turns * 5, current: true)
        fake.failGapPages(true)
        let (hub, source, store, link) = try await Self.reconnect(fake, missedThrough: last)
        defer { withExtendedLifetime((hub, link)) {} }
        await Self.waitUntil { Self.shows(store, last) && fake.gapPageCount > 0 }

        #expect(store.turns.map(\.id) == Self.ids(0..<Chat.turns) + Self.ids((last - 79)...last))
        #expect(source.gapFill == AcpmuxSessionSource.GapFill(cursor: Chat.turns * 5, end: (last - 79) * 5 + 1))
        // Only the gap's pages: no read after the newest page.
        #expect(fake.eventsCallCount == fake.gapPageCount)
        // One attach on the reconnect, written right behind initialize and the watch.
        #expect(Array(fake.methods.prefix(3)) == ["initialize", "_acpmux/watch", "_acpmux/attach"])
        #expect(fake.methods.filter { $0 == "_acpmux/attach" }.count == 1)
        #expect(hub.pipelinedAttachesRead == 1)
        #expect(fake.recordsSent == 400)
    }

    /// An older Mac (new phone, old Mac): no `pageThrough` in its reply, so the read after the
    /// newest page still goes, and no attach rides with `initialize` (it names no kinds).
    @Test func anOlderMacStillGetsTheReadAfterTheNewestPage() async throws {
        let last = Self.narrowMissed
        let fake = Fake(turns: 0..<(last + 1), visibleThrough: Chat.turns * 5)
        fake.failGapPages(true)
        let (hub, _, store, link) = try await Self.reconnect(fake, missedThrough: last)
        defer { withExtendedLifetime((hub, link)) {} }
        await Self.waitUntil { Self.shows(store, last) && fake.gapPageCount > 0 }

        #expect(fake.eventsCallCount == fake.gapPageCount + 1)
        #expect(hub.pipelinedAttachesRead == 0)
    }

    /// The first connection since launch with the chat already open (a cold launch back into
    /// it): its attach goes right behind `initialize` and the watch with every kind the phone
    /// draws, and a current Mac's reply is read from that write: one round trip to the page.
    @Test func aFirstConnectionWithTheChatOpenSendsItsAttachWithInitialize() async throws {
        let fake = Fake(turns: 0..<Chat.turns, visibleThrough: Chat.turns * 5, current: true)
        let link = fake.link()
        let hub = AcpmuxHub()
        let source = hub.source(sessionID: "s1", summary: Chat.summary)
        let store = AgentChatStore(source: source)
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        defer { withExtendedLifetime((hub, link)) {} }
        await Self.waitUntil { store.turns.count == Chat.turns }

        #expect(store.turns.map(\.id) == Self.ids(0..<Chat.turns))
        #expect(Array(fake.methods.prefix(3)) == ["initialize", "_acpmux/watch", "_acpmux/attach"])
        #expect(fake.methods.filter { $0 == "_acpmux/attach" }.count == 1)
        #expect(hub.pipelinedAttachesRead == 1)
    }

    /// The same cold launch against an older Mac (its `initialize` names no capabilities): the
    /// written attach asked for kinds it does not serve, so it is asked again with the kinds it
    /// does, and the chat shows the same turns. Its next connection writes no attach early.
    @Test func aFirstConnectionToAnOlderMacAsksTheAttachAgain() async throws {
        let fake = Fake(turns: 0..<Chat.turns, visibleThrough: Chat.turns * 5)
        let link = fake.link()
        let hub = AcpmuxHub()
        let source = hub.source(sessionID: "s1", summary: Chat.summary)
        let store = AgentChatStore(source: source)
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        defer { withExtendedLifetime((hub, link)) {} }
        await Self.waitUntil { store.turns.count == Chat.turns }

        #expect(store.turns.map(\.id) == Self.ids(0..<Chat.turns))
        #expect(fake.methods.filter { $0 == "_acpmux/attach" }.count == 2)
        #expect(hub.pipelinedAttachesRead == 0)

        await hub.bind(nil)
        fake.resetCounts()
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        await Self.waitUntil { fake.methods.contains("_acpmux/attach") }
        #expect(Array(fake.methods.prefix(2)) == ["initialize", "_acpmux/watch"])
        #expect(fake.methods.filter { $0 == "_acpmux/attach" }.count == 1)
    }

    /// `pageReachesEnd` reads only a reply that says so.
    @Test func pageReachesEndNeedsPageThroughAtLastSeq() {
        typealias S = AcpmuxSessionSource
        #expect(S.pageReachesEnd(.object(["lastSeq": .number(9), "pageThrough": .number(9)])))
        #expect(!S.pageReachesEnd(.object(["lastSeq": .number(9), "pageThrough": .number(7)])))
        #expect(!S.pageReachesEnd(.object(["lastSeq": .number(9)])))
    }
}

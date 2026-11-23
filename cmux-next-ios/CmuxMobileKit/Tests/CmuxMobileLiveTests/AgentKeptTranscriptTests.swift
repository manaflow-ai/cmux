import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Opening an agent chat that exists never shows the empty new-chat screen (user 2026-11-09: "when I
/// open an existing agent GUI I get shown a new chat UI until the full chat loads"). The phone keeps
/// each chat's newest records on disk, bounded, and draws them at once; with none kept it shows a
/// loading state; the attach then reads only what came after the kept records.
@MainActor
@Suite(.timeLimit(.minutes(2))) struct AgentKeptTranscriptTests {
    typealias Long = LongChatOpenLiveTests

    static let summary = AgentSessionSummary(id: "s7", name: "Fix", harness: "codex", agentName: "Codex", cwd: "/tmp/w",
                                             workspaceTitle: "w", macName: "mini", macID: "mac1", accountID: "acct")

    static func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "agent-kept-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    static func cache(_ directory: URL = folder(), totalBytes: Int = 48 << 20, entryBytes: Int = 512 * 1024,
                      recordLimit: Int = 600) -> AgentTranscriptCache {
        AgentTranscriptCache(directory: directory, recordLimit: recordLimit, entryBytes: entryBytes, totalBytes: totalBytes,
                             writeDelay: .milliseconds(0))
    }

    static func json(_ records: [(seq: Int, json: String)]) -> [JSONValue] {
        records.compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.json.utf8)) }
    }

    static func hub(_ cache: AgentTranscriptCache?) -> AcpmuxHub {
        let hub = AcpmuxHub()
        hub.transcriptCache = cache
        return hub
    }

    // MARK: Store load state

    /// A chat whose history is on its way is not a new chat: before any record arrives the store
    /// says it is loading (the screen shows a spinner, not "What should Codex do?").
    @Test func existingChatLoadsInsteadOfShowingNewChat() async throws {
        let hub = Self.hub(nil)
        let store = AgentChatStore(source: hub.source(sessionID: "s1", summary: Self.summary))
        #expect(store.isLoadingHistory)
        #expect(!store.isNewChat)
        #expect(!store.hasTurns)

        // The link comes and the attach catches up: loaded, with the Mac's turns.
        let requests = Long.Requests()
        await hub.bind(try await Long.fakeAcpmux((0..<3).flatMap(Long.turnRecords), requests).openChannel(service: "acpmux", args: [:]))
        await Long.waitUntil { !store.isLoadingHistory }
        #expect(store.turns.last?.id == "t2")
        #expect(!store.isNewChat)
    }

    /// A source with nothing to read (a mock, an unbound tab) is a new chat at once.
    @Test func sourceWithoutHistoryIsNewChat() {
        let store = AgentChatStore(source: DisconnectedAgentSource(summary: Self.summary))
        #expect(!store.isLoadingHistory)
        #expect(store.isNewChat)
    }

    // MARK: Kept transcript

    /// After one open, a new hub (a relaunch, the link not up yet) shows the kept turns at once,
    /// still loading; when the link comes the attach reads after the newest kept seq (not the
    /// first-open page), and the chat ends current with the turns the Mac added meanwhile.
    @Test func reopenShowsKeptTurnsThenCatchesUpAfterThem() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = Self.cache(directory)
        var log = (0..<5).flatMap(Long.turnRecords)

        do {
            let requests = Long.Requests()
            let hub = Self.hub(cache)
            await hub.bind(try await Long.fakeAcpmux(log, requests).openChannel(service: "acpmux", args: [:]))
            let store = AgentChatStore(source: hub.source(sessionID: "s1", summary: Self.summary))
            await Long.waitUntil { store.turns.last?.id == "t4" && !store.isLoadingHistory }
            #expect(store.turns.last?.id == "t4")
        }
        cache.flush()
        let key = try #require(AgentTranscriptCache.key(accountID: "acct", macID: "mac1", tabID: "s7"))
        #expect(cache.cached(key)?.lastSeq == 25)

        // Relaunch: a fresh cache reads the file; the hub has no link yet.
        let relaunched = Self.cache(directory)
        let hub = Self.hub(relaunched)
        let store = AgentChatStore(source: hub.source(sessionID: "s1", summary: Self.summary))
        await Long.waitUntil { store.turns.count == 5 }
        #expect(store.turns.map(\.id) == ["t0", "t1", "t2", "t3", "t4"])
        #expect(store.isLoadingHistory)
        #expect(!store.isNewChat)

        // Meanwhile the Mac ran two more turns.
        log += (5..<7).flatMap(Long.turnRecords)
        let requests = Long.Requests()
        await hub.bind(try await Long.fakeAcpmux(log, requests).openChannel(service: "acpmux", args: [:]))
        await Long.waitUntil { store.turns.last?.id == "t6" && !store.isLoadingHistory }
        #expect(store.turns.map(\.id) == ["t0", "t1", "t2", "t3", "t4", "t5", "t6"])
        let attach = try #require(requests.all.first { $0.method == "_acpmux/attach" })
        #expect((attach.params["afterSeq"] as? NSNumber)?.intValue == 25)
        #expect(attach.params["maxBytes"] == nil)
    }

    /// Leo, 2026-11-14: "i also want all our connectivity stuff to shut the f*** up and load
    /// faster/percievably load faster". A relaunch (a fresh cache, only the disk holds the chat)
    /// restores the kept turns in the source's init, in the same turn, so the reopened chat's
    /// first frame draws them. Before, they came from a disk read off the main thread and the
    /// first frame showed "Loading chat…".
    @Test func aRelaunchRestoresTheKeptTurnsInTheSameTurn() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try #require(AgentTranscriptCache.key(accountID: "acct", macID: "mac1", tabID: "s7"))
        let writer = Self.cache(directory)
        writer.save(key, sessionID: "s1", earlier: false, records: Self.json((0..<5).flatMap(Long.turnRecords)))
        writer.flush()

        let relaunched = Self.cache(directory)
        let source = Self.hub(relaunched).source(sessionID: "s1", summary: Self.summary)
        #expect(source.replayCount > 0, "the kept turns, restored in init")
        let store = AgentChatStore(source: source)
        await Long.waitUntil { store.turns.count == 5 }
        #expect(store.turns.map(\.id) == ["t0", "t1", "t2", "t3", "t4"])
    }

    /// The first frame reads only the head: the newest turns, bounded, from a prompt, marked
    /// `earlier`; the whole kept copy stays on disk for the next save and the offline reader.
    @Test func theHeadHoldsOnlyTheNewestTurns() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try #require(AgentTranscriptCache.key(accountID: "acct", macID: "mac1", tabID: "s7"))
        let writer = Self.cache(directory)
        writer.save(key, sessionID: "s1", earlier: false, records: Self.json((0..<120).flatMap(Long.turnRecords)))
        writer.flush()

        let relaunched = Self.cache(directory)
        let head = try #require(relaunched.firstScreen(key))
        #expect(head.records.count <= AgentTranscriptCache.firstScreenRecords)
        #expect(head.earlier)
        #expect(head.lastSeq == 600)
        #expect(AgentTranscriptCache.isPrompt(try #require(head.records.first)))
        #expect(await relaunched.load(key)?.records.count == 600)

        let store = AgentChatStore(source: Self.hub(Self.cache(directory)).source(sessionID: "s1", summary: Self.summary))
        await Long.waitUntil { store.turns.last?.id == "t119" }
        #expect(store.turns.count == head.records.count / 5)
    }

    // MARK: Partial writes and the whole copy's refill (head file + whole copy)

    static func seqs(_ entry: AgentTranscriptEntry?) -> [Int] {
        entry?.records.map { Int($0["seq"]?.numberValue ?? 0) } ?? []
    }

    static func onDisk(_ url: URL) -> AgentTranscriptEntry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AgentTranscriptEntry.self, from: data)
    }

    /// 120 turns kept (seq 1...600, the head the newest of them); the Mac has run three more since
    /// (seq 601...615). The fake's log holds fewer than one page, so the attach from the kept copy
    /// reads forward (more than a page behind would drop the kept copy, ``keptCopyTooFarBehindOpensFresh``).
    static let keptTurns = 120
    static let macLog = (60..<123).flatMap(Long.turnRecords)
    static let macTurnIDs = (0..<123).map { "t\($0)" }

    static func keepWholeAndHead(_ directory: URL, _ key: String, turns: Int = keptTurns) {
        let writer = cache(directory)
        writer.save(key, sessionID: "s1", earlier: false, records: json((0..<turns).flatMap(Long.turnRecords)))
        writer.flush()
    }

    /// Opens the chat on a relaunch's cache, lets the Mac answer, and returns the store, the
    /// attach's request, and whether the kept turns were restored in the source's init.
    static func reopenAndCatchUp(_ cache: AgentTranscriptCache, beforeBind: (AgentChatStore) async -> Void = { _ in })
        async throws -> (store: AgentChatStore, attach: (method: String, params: [String: Any]), sameTurn: Bool) {
        let hub = hub(cache)
        let source = hub.source(sessionID: "s1", summary: summary)
        let sameTurn = source.replayCount > 0
        let store = AgentChatStore(source: source)
        await beforeBind(store)
        let requests = Long.Requests()
        await hub.bind(try await Long.fakeAcpmux(macLog, requests).openChannel(service: "acpmux", args: [:]))
        await Long.waitUntil { store.turns.last?.id == "t122" && !store.isLoadingHistory }
        let attach = try #require(requests.all.first { $0.method == "_acpmux/attach" })
        #expect(requests.count("_acpmux/attach") == 1, "one attach: the kept copy was not dropped")
        return (store, attach, sameTurn)
    }

    /// The turns end in order, each once, through the Mac's newest.
    static func expectInOrderThroughNewest(_ store: AgentChatStore) {
        let ids = store.turns.map(\.id)
        #expect(Set(ids).count == ids.count, "no turn twice")
        #expect(ids.last == "t122")
        let first = ids.first.flatMap { macTurnIDs.firstIndex(of: $0) } ?? 0
        #expect(ids == Array(macTurnIDs[first...]), "the turns in order with none missing")
    }

    /// Both files hold the same records after the next save: contiguous through seq 615, from a
    /// prompt, the head the newest of the whole copy; nothing older than what was saved stays.
    static func expectBothFilesCurrent(_ cache: AgentTranscriptCache, _ key: String, wholeFrom: Int) throws {
        cache.flush()
        let whole = try #require(onDisk(cache.file(for: key)), "the whole copy written again")
        let head = try #require(onDisk(cache.headFile(for: key)), "the head written again")
        // The whole copy keeps at most `recordLimit` records, from a prompt: of 615, seq 16 (turn
        // 3's prompt) on. Each turn is five records, its prompt at 5n+1.
        let bound = max(wholeFrom, ((615 - cache.recordLimit + 1) + 3) / 5 * 5 + 1)
        #expect(seqs(whole) == Array(bound...615))
        #expect(whole.earlier == (bound > 1))
        #expect(head.lastSeq == 615)
        #expect(seqs(whole).suffix(head.records.count) == seqs(head)[...])
        #expect(AgentTranscriptCache.isPrompt(try #require(whole.records.first)))
        #expect(AgentTranscriptCache.isPrompt(try #require(head.records.first)))
    }

    /// Partial write: the head is on disk without its whole copy (the whole copy's write failed,
    /// or it was trimmed away). The chat still opens on the head's turns in the same turn, the
    /// attach reads after the head's newest seq, and the next save writes both files again.
    @Test func aHeadWithoutItsWholeCopyOpensAndTheNextSaveWritesBoth() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try #require(AgentTranscriptCache.key(accountID: "acct", macID: "mac1", tabID: "s7"))
        Self.keepWholeAndHead(directory, key)
        let probe = Self.cache(directory)
        try FileManager.default.removeItem(at: probe.file(for: key))
        let head = try #require(Self.onDisk(probe.headFile(for: key)))
        #expect(head.lastSeq == 600)

        let relaunched = Self.cache(directory)
        let (store, attach, sameTurn) = try await Self.reopenAndCatchUp(relaunched)
        #expect(sameTurn, "the head's turns, restored in init")
        #expect((attach.params["afterSeq"] as? NSNumber)?.intValue == 600)
        Self.expectInOrderThroughNewest(store)
        #expect(store.turns.first?.id == head.records.first?["msg"]?["turnId"]?.stringValue)
        try Self.expectBothFilesCurrent(relaunched, key, wholeFrom: try #require(Self.seqs(head).first))
    }

    /// Partial write: the whole copy is on disk without a head (kept before head files, or the
    /// head's write failed). The chat opens from the whole copy, read off the main thread, the
    /// attach waits for it and reads after its newest seq, and the next save writes both.
    @Test func aWholeCopyWithoutItsHeadOpensAndTheNextSaveWritesBoth() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try #require(AgentTranscriptCache.key(accountID: "acct", macID: "mac1", tabID: "s7"))
        Self.keepWholeAndHead(directory, key)
        try FileManager.default.removeItem(at: Self.cache(directory).headFile(for: key))

        let relaunched = Self.cache(directory)
        #expect(relaunched.firstScreen(key) == nil)
        let (store, attach, sameTurn) = try await Self.reopenAndCatchUp(relaunched) { store in
            await Long.waitUntil { store.turns.count == Self.keptTurns }
        }
        #expect(!sameTurn, "no head: the whole copy is read off the main thread")
        #expect((attach.params["afterSeq"] as? NSNumber)?.intValue == 600)
        Self.expectInOrderThroughNewest(store)
        #expect(store.turns.first?.id == "t0")
        try Self.expectBothFilesCurrent(relaunched, key, wholeFrom: 1)
    }

    /// Failed write: a head cut short (the app killed mid-write, a bad sector) is no head. The
    /// chat opens from the whole copy and the next save writes a good head.
    @Test func aBrokenHeadOpensFromTheWholeCopy() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try #require(AgentTranscriptCache.key(accountID: "acct", macID: "mac1", tabID: "s7"))
        Self.keepWholeAndHead(directory, key)
        let headURL = Self.cache(directory).headFile(for: key)
        let cut = try Data(contentsOf: headURL).prefix(200)
        try cut.write(to: headURL)

        let relaunched = Self.cache(directory)
        #expect(relaunched.firstScreen(key) == nil)
        let (store, attach, sameTurn) = try await Self.reopenAndCatchUp(relaunched) { store in
            await Long.waitUntil { store.turns.count == Self.keptTurns }
        }
        #expect(!sameTurn, "no head: the whole copy is read off the main thread")
        #expect((attach.params["afterSeq"] as? NSNumber)?.intValue == 600)
        Self.expectInOrderThroughNewest(store)
        try Self.expectBothFilesCurrent(relaunched, key, wholeFrom: 1)
    }

    /// Partial write: the app stopped between the whole copy's write and the head's, so the head
    /// is a save behind (seq 600, the whole copy 610). The chat opens on the head; the whole copy's
    /// refill does not land (it is not the head's copy: its records past 600 would come twice);
    /// the attach reads after 600; nothing is shown twice or kept twice.
    @Test func aHeadBehindItsWholeCopyNeverDoublesTurns() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try #require(AgentTranscriptCache.key(accountID: "acct", macID: "mac1", tabID: "s7"))
        Self.keepWholeAndHead(directory, key)
        let headURL = Self.cache(directory).headFile(for: key)
        let oldHead = try Data(contentsOf: headURL)
        Self.keepWholeAndHead(directory, key, turns: 122)
        try oldHead.write(to: headURL)

        let relaunched = Self.cache(directory)
        let head = try #require(relaunched.firstScreen(key))
        #expect(head.earlier)
        #expect(head.lastSeq == 600)
        let (store, attach, sameTurn) = try await Self.reopenAndCatchUp(relaunched) { _ in
            // The refill's read of the whole copy is done (it remembers what it read).
            await Long.waitUntil { relaunched.cached(key)?.lastSeq == 610 }
            await Task.yield()
        }
        #expect(sameTurn, "the head's turns, restored in init")
        #expect((attach.params["afterSeq"] as? NSNumber)?.intValue == 600)
        Self.expectInOrderThroughNewest(store)
        let kept = Self.seqs(relaunched.cached(key))
        #expect(kept == Array(try #require(Self.seqs(head).first)...615), "the head's records, then the Mac's, each once")
        try Self.expectBothFilesCurrent(relaunched, key, wholeFrom: try #require(Self.seqs(head).first))
    }

    /// Partial write the other way: the whole copy's write failed and the head's landed, so the
    /// head is ahead (seq 610, the whole copy 600). The chat opens on the head, the refill does
    /// not land (it would drop records 601...610), the attach reads after 610.
    @Test func aHeadAheadOfItsWholeCopyKeepsItsNewestTurns() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try #require(AgentTranscriptCache.key(accountID: "acct", macID: "mac1", tabID: "s7"))
        Self.keepWholeAndHead(directory, key)
        let wholeURL = Self.cache(directory).file(for: key)
        let oldWhole = try Data(contentsOf: wholeURL)
        Self.keepWholeAndHead(directory, key, turns: 122)
        try oldWhole.write(to: wholeURL)

        let relaunched = Self.cache(directory)
        let head = try #require(relaunched.firstScreen(key))
        #expect(head.lastSeq == 610)
        let (store, attach, sameTurn) = try await Self.reopenAndCatchUp(relaunched) { _ in
            await Long.waitUntil { relaunched.cached(key)?.lastSeq == 600 }
            await Task.yield()
        }
        #expect(sameTurn, "the head's turns, restored in init")
        #expect((attach.params["afterSeq"] as? NSNumber)?.intValue == 610)
        Self.expectInOrderThroughNewest(store)
        #expect(Self.seqs(relaunched.cached(key)) == Array(try #require(Self.seqs(head).first)...615))
        try Self.expectBothFilesCurrent(relaunched, key, wholeFrom: try #require(Self.seqs(head).first))
    }

    /// Attach/refill order: the whole copy's refill lands before the attach. The chat drew the
    /// head; the attach reads after the head's newest seq (600), and the kept copy saved after it
    /// is the whole copy's records then the Mac's newer ones, in order, each once.
    @Test func theRefillBeforeTheAttachKeepsTheWholeCopyThenTheNewerRecords() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try #require(AgentTranscriptCache.key(accountID: "acct", macID: "mac1", tabID: "s7"))
        Self.keepWholeAndHead(directory, key)

        let relaunched = Self.cache(directory)
        let head = try #require(relaunched.firstScreen(key))
        #expect(head.earlier && head.lastSeq == 600)
        let (store, attach, sameTurn) = try await Self.reopenAndCatchUp(relaunched) { _ in
            await Long.waitUntil { relaunched.cached(key)?.records.count == 600 }
            await Task.yield()
        }
        #expect(sameTurn, "the head's turns, restored in init")
        #expect((attach.params["afterSeq"] as? NSNumber)?.intValue == 600)
        Self.expectInOrderThroughNewest(store)
        #expect(Self.seqs(relaunched.cached(key)) == Array(1...615), "the whole copy, then 601...615, each once")
        try Self.expectBothFilesCurrent(relaunched, key, wholeFrom: 1)
    }

    /// Attach/refill order: the whole copy's refill lands after the attach caught up (its read held
    /// on the cache's queue until then). The newer records the attach applied stay, in order, each
    /// once; the late refill changes nothing; the attach read after the head's newest seq.
    @Test func theRefillAfterTheAttachNeverDropsOrReordersTheNewerRecords() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try #require(AgentTranscriptCache.key(accountID: "acct", macID: "mac1", tabID: "s7"))
        Self.keepWholeAndHead(directory, key)

        let relaunched = Self.cache(directory)
        let head = try #require(relaunched.firstScreen(key))
        let headFirst = try #require(Self.seqs(head).first)
        // Holds the cache's queue: the refill's disk read waits behind it.
        let gate = DispatchSemaphore(value: 0)
        relaunched.queue.async { gate.wait() }
        let (store, attach, sameTurn) = try await Self.reopenAndCatchUp(relaunched)
        #expect(sameTurn, "the head's turns, restored in init")
        #expect((attach.params["afterSeq"] as? NSNumber)?.intValue == 600)
        let caughtUp = Self.seqs(relaunched.cached(key))
        #expect(caughtUp == Array(headFirst...615))
        let turnsCaughtUp = store.turns.map(\.id)

        gate.signal()
        relaunched.flush()
        for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(10)) } // test: lets the late refill resume
        #expect(Self.seqs(relaunched.cached(key)) == caughtUp, "the late refill changed nothing")
        #expect(store.turns.map(\.id) == turnsCaughtUp)
        Self.expectInOrderThroughNewest(store)
        try Self.expectBothFilesCurrent(relaunched, key, wholeFrom: headFirst)
    }

    /// A read of the whole copy in flight when the chat's kept copy is forgotten (the attach found
    /// it too old, ``keptCopyTooFarBehindOpensFresh``) never puts it back in memory: the source
    /// rebuilt after the drop would restore the stale turns again (review F1 at e54b7ec1).
    @Test func aReadInFlightWhenTheChatIsForgottenNeverBringsItBack() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try #require(AgentTranscriptCache.key(accountID: "acct", macID: "mac1", tabID: "s7"))
        Self.keepWholeAndHead(directory, key)

        let relaunched = Self.cache(directory)
        // Holds the cache's queue: the read waits behind it, the file still on disk.
        let gate = DispatchSemaphore(value: 0)
        relaunched.queue.async { gate.wait() }
        let read = Task { await relaunched.load(key) }
        for _ in 0..<5 { await Task.yield() } // test: lets the read start and wait on the queue
        relaunched.forget(key)
        gate.signal()
        #expect(await read.value == nil, "the read that started before the forget does not land")
        #expect(relaunched.cached(key) == nil)
        relaunched.flush()
        #expect(!FileManager.default.fileExists(atPath: relaunched.file(for: key).path(percentEncoded: false)))
        #expect(relaunched.firstScreen(key) == nil)
    }

    /// Records kept for another session of the tab (the Mac started a new one) are not shown.
    @Test func keptRecordsOfAnotherSessionAreIgnored() async throws {
        let cache = Self.cache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let key = try #require(AgentTranscriptCache.key(accountID: "acct", macID: "mac1", tabID: "s7"))
        cache.save(key, sessionID: "old-session", earlier: false, records: Self.json(Long.turnRecords(0)))
        let hub = Self.hub(cache)
        let source = hub.source(sessionID: "s1", summary: Self.summary)
        let store = AgentChatStore(source: source)
        // The entry is in memory: a restore would have run in the source's init.
        #expect(source.replayCount == 0)
        await Task.yield()
        #expect(store.turns.isEmpty)
        #expect(store.isLoadingHistory)
    }

    /// A kept copy far behind the Mac (more than one page since it) is dropped: the chat opens on a
    /// first attach (one bounded page), not a forward read of everything since.
    @Test func keptCopyTooFarBehindOpensFresh() async throws {
        let cache = Self.cache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let key = try #require(AgentTranscriptCache.key(accountID: "acct", macID: "mac1", tabID: "s7"))
        cache.save(key, sessionID: "s1", earlier: false, records: Self.json(Long.turnRecords(0)))
        let hub = Self.hub(cache)
        let source = hub.source(sessionID: "s1", summary: Self.summary)
        // The coordinator builds the chat's store again on a reset (`onReset`); so does this.
        final class Holder { var store: AgentChatStore?; var resets = 0 }
        let holder = Holder()
        holder.store = AgentChatStore(source: source)
        source.onReset = {
            holder.resets += 1
            holder.store = AgentChatStore(source: source)
        }
        #expect(holder.store?.turns.isEmpty == false || source.replayCount > 0)
        // 1000 turns since: far past one 400-record page.
        let requests = Long.Requests()
        await hub.bind(try await Long.fakeAcpmux((0..<1000).flatMap(Long.turnRecords), requests).openChannel(service: "acpmux", args: [:]))
        await Long.waitUntil { holder.resets == 1 && holder.store?.turns.last?.id == "t999" && holder.store?.isLoadingHistory == false }
        let store = try #require(holder.store)
        #expect(holder.resets == 1)
        #expect(store.turns.last?.id == "t999")
        #expect(store.turns.first?.id != "t0")
        let attaches = requests.all.filter { $0.method == "_acpmux/attach" }
        #expect(attaches.count == 2)
        #expect((attaches.first?.params["afterSeq"] as? NSNumber)?.intValue == 5)
        #expect(attaches.last?.params["maxBytes"] != nil)
        #expect(attaches.last?.params["afterSeq"] == nil)
        #expect(requests.count("_acpmux/events") == 0)
        #expect(cache.cached(key)?.records.first?["msg"]?["turnId"]?.stringValue != "t0")
    }

    /// An ask kept on the phone is not shown from the kept copy (it may have been answered on the
    /// Mac since); only the attach reply's pending list brings back the open ones.
    @Test func keptAsksAreNotShownUntilTheMacListsThem() async throws {
        let cache = Self.cache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let key = try #require(AgentTranscriptCache.key(accountID: "acct", macID: "mac1", tabID: "s7"))
        let ask = #"{"sessionId":"s1","seq":6,"at":2,"dir":"mux","kind":"permission_request","msg":{"permissionId":"perm1","request":{"sessionId":"s1","toolCall":{"toolCallId":"tc1","title":"Run ls","kind":"execute"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"}]}}}"#
        let records = Self.json([Long.turnRecords(0)[0], (6, ask)])
        cache.save(key, sessionID: "s1", earlier: false, records: records)
        let hub = Self.hub(cache)
        let store = AgentChatStore(source: hub.source(sessionID: "s1", summary: Self.summary))
        await Long.waitUntil { store.hasTurns }
        #expect(store.hasTurns)
        #expect(store.pendingPermission == nil)
    }

    /// Once the hub's cache is taken away (sign-out), a link drop saves nothing back.
    @Test func noSaveAfterTheCacheIsTakenAway() async throws {
        let cache = Self.cache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let hub = Self.hub(cache)
        let requests = Long.Requests()
        await hub.bind(try await Long.fakeAcpmux((0..<3).flatMap(Long.turnRecords), requests).openChannel(service: "acpmux", args: [:]))
        let store = AgentChatStore(source: hub.source(sessionID: "s1", summary: Self.summary))
        await Long.waitUntil { !store.isLoadingHistory }
        cache.removeAll()
        hub.transcriptCache = nil
        await hub.bind(nil)
        cache.flush()
        let key = try #require(AgentTranscriptCache.key(accountID: "acct", macID: "mac1", tabID: "s7"))
        #expect(cache.cached(key) == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.directory.path(percentEncoded: false)))
    }

    /// Nothing is kept for a chat no account owns.
    @Test func noAccountKeepsNothing() {
        #expect(AgentTranscriptCache.key(accountID: "", macID: "mac1", tabID: "s7") == nil)
    }

    // MARK: Bounds

    /// Each chat keeps its newest records, cut at a prompt, under the record limit.
    @Test func entryKeepsNewestRecordsFromAPrompt() throws {
        let records = Self.json((0..<10).flatMap(Long.turnRecords))
        let data = try #require(AgentTranscriptCache.encoded(
            AgentTranscriptEntry(sessionID: "s1", earlier: false, records: records), recordLimit: 12, entryBytes: .max))
        let entry = try JSONDecoder().decode(AgentTranscriptEntry.self, from: data)
        // 12 newest records start inside turn 7; the kept copy starts at turn 8's prompt.
        #expect(entry.records.first?["msg"]?["turnId"]?.stringValue == "t8")
        #expect(entry.records.count == 10)
        #expect(entry.earlier)
    }

    /// Each chat keeps at most `entryBytes`, dropping its oldest turns.
    @Test func entryKeepsUnderItsByteCap() throws {
        let records = Self.json((0..<40).flatMap(Long.turnRecords))
        let cap = 4 * 1024
        let data = try #require(AgentTranscriptCache.encoded(
            AgentTranscriptEntry(sessionID: "s1", earlier: false, records: records), recordLimit: 10_000, entryBytes: cap))
        #expect(data.count <= cap)
        let entry = try JSONDecoder().decode(AgentTranscriptEntry.self, from: data)
        #expect(entry.records.last?["msg"]?["turnId"]?.stringValue == "t39")
        #expect(entry.records.first?["kind"]?.stringValue == "user_message")
        #expect(entry.earlier)
    }

    /// All chats together stay under `totalBytes`: the chats written longest ago go first, the newest stays.
    @Test func totalCapEvictsOldestChats() async throws {
        let cache = Self.cache(totalBytes: 12 * 1024)
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let records = Self.json((0..<6).flatMap(Long.turnRecords))
        var keys: [String] = []
        for index in 0..<10 {
            let key = "acct|mac1|tab\(index)"
            keys.append(key)
            cache.save(key, sessionID: "s\(index)", earlier: false, records: records)
            cache.flush()
            // Distinct modification dates, oldest first.
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1_000 + index))],
                                                  ofItemAtPath: cache.file(for: key).path(percentEncoded: false))
        }
        let files = try FileManager.default.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: [.fileSizeKey])
        let total = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        #expect(total <= 12 * 1024)
        #expect(FileManager.default.fileExists(atPath: cache.file(for: keys[9]).path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: cache.file(for: keys[0]).path(percentEncoded: false)))
    }

    /// Sign-out deletes every kept chat, in memory and on disk.
    @Test func removeAllDeletesEverything() throws {
        let cache = Self.cache()
        let key = "acct|mac1|s7"
        cache.save(key, sessionID: "s1", earlier: false, records: Self.json(Long.turnRecords(0)))
        cache.flush()
        #expect(FileManager.default.fileExists(atPath: cache.file(for: key).path(percentEncoded: false)))
        cache.removeAll()
        cache.flush()
        #expect(cache.cached(key) == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.directory.path(percentEncoded: false)))
    }
}

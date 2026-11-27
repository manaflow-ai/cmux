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

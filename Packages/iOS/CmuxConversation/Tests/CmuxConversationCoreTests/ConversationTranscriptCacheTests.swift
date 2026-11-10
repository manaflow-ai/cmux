import Foundation
import Testing
@testable import CmuxConversationCore

/// A Chief conversation keeps its newest messages on the phone, the way Messages and WhatsApp do:
/// a store built again (the app back from the background, a relaunch, a reconnect) shows them at
/// once instead of a spinner, and the server's newest page then replaces them (the user,
/// 2026-11-06: "so I don't just see a loading spinner when I come back from app background").
/// Before, every new store started empty and showed the spinner until the page arrived.
@MainActor
@Suite(.serialized) struct ConversationTranscriptCacheTests {
    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "transcripts-\(UUID().uuidString)")
    }

    /// A store reads the newest page and keeps it.
    static func loadedStore(_ backend: ScriptedBackend, cache: ConversationTranscriptCache, key: String) async throws -> ConversationStore {
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.useTranscriptCache(cache, key: key)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest && cache.cached(key)?.messages.count == 30 }
        return store
    }

    @Test func aStoreBuiltAgainShowsTheKeptMessagesAtOnceThenTheServers() async throws {
        let cache = ConversationTranscriptCache(directory: Self.directory())
        defer { cache.removeAll() }
        let backend = ScriptedBackend(total: 100)
        _ = try await Self.loadedStore(backend, cache: cache, key: "mac:m1")

        // The app comes back: a new store for the same Chief, before any page.
        backend.total = 103
        let again = ConversationStore(backend: backend, pageSize: 30)
        var changes: [ConversationStoreChange] = []
        again.onChange = { changes.append($0) }
        again.useTranscriptCache(cache, key: "mac:m1")
        // In the same turn: no spinner frame.
        #expect(again.messages.compactMap(\.seq) == Array(71...100))
        #expect(again.isShowingKeptTranscript)
        #expect(!again.hasLoadedNewest)
        #expect(again.meID == "me")
        #expect(again.info?.title == "cmux")
        #expect(changes == [.reset])

        // The server's newest page replaces them, with what arrived meanwhile.
        again.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { again.hasLoadedNewest }
        #expect(again.messages.compactMap(\.seq) == Array(74...103))
        #expect(!again.isShowingKeptTranscript)
        try await waitUntil { cache.cached("mac:m1")?.messages.last?.seq == 103 }
    }

    /// A relaunch: a new cache over the same folder reads the kept messages from disk.
    @Test func aRelaunchReadsThemFromDisk() async throws {
        let directory = Self.directory()
        let first = ConversationTranscriptCache(directory: directory)
        _ = try await Self.loadedStore(ScriptedBackend(total: 100), cache: first, key: "cloud:c1")
        first.flush()

        let relaunched = ConversationTranscriptCache(directory: directory)
        defer { relaunched.removeAll() }
        #expect(relaunched.cached("cloud:c1") == nil)
        let store = ConversationStore(backend: ScriptedBackend(total: 100), pageSize: 30)
        store.useTranscriptCache(relaunched, key: "cloud:c1")
        try await waitUntil { store.messages.count == 30 }
        #expect(store.messages.compactMap(\.seq) == Array(71...100))
        #expect(store.isShowingKeptTranscript)
        // Another Chief's key has nothing.
        #expect(await relaunched.load("cloud:other") == nil)
    }

    /// The server's page may land while the disk read runs: the read, done later, does not
    /// replace it.
    @Test func theServersPageWinsOverALateRead() async throws {
        let directory = Self.directory()
        let first = ConversationTranscriptCache(directory: directory)
        _ = try await Self.loadedStore(ScriptedBackend(total: 50), cache: first, key: "k")
        first.flush()
        let relaunched = ConversationTranscriptCache(directory: directory)
        defer { relaunched.removeAll() }
        // The read waits behind this until the page is in.
        let gate = DispatchSemaphore(value: 0)
        relaunched.queue.async { gate.wait() }
        let backend = ScriptedBackend(total: 200)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.useTranscriptCache(relaunched, key: "k")
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        gate.signal()
        // The read lands (the page's own save may have beaten it into memory).
        try await waitUntil { relaunched.cached("k") != nil }
        #expect(store.messages.compactMap(\.seq) == Array(171...200))
        #expect(!store.isShowingKeptTranscript)
    }

    /// The newest `limit` acknowledged messages are kept: no unsent send (the outbox owns it),
    /// no Send Later row, no image bytes picked on the phone.
    @Test func keepsTheNewestAcknowledgedMessagesOnly() {
        let image = ConversationAttachment(id: "a", kind: .image, width: 4, height: 3, url: URL(string: "https://example.com/a.jpg"),
                                           localData: Data([1, 2, 3]))
        var messages = (1...300).map { ConversationMessage(id: "m\($0)", seq: $0, clientMessageID: nil, senderID: "lc",
                                                           sentAt: Date(timeIntervalSince1970: Double($0)), text: "m\($0)") }
        messages[299].attachments = [image]
        messages.append(ConversationMessage(id: "local:x", seq: nil, clientMessageID: "x", senderID: "me", sentAt: Date(), text: "sending"))
        let snapshot = ConversationTranscriptCache.snapshot(info: nil, meID: "me", messages: messages, limit: 200)
        #expect(snapshot.messages.count == 200)
        #expect(snapshot.messages.first?.seq == 101)
        #expect(snapshot.messages.last?.seq == 300)
        #expect(snapshot.messages.last?.attachments.first?.localData == nil)
        #expect(snapshot.messages.last?.attachments.first?.url != nil)
    }

    /// Everything a row shows survives the disk: reactions, a poll, a link card, a receipt,
    /// formatting, mentions, an audio message and a group change.
    @Test func aRichMessageRoundTrips() throws {
        let message = ConversationMessage(
            id: "m1", seq: 1, clientMessageID: "c1", senderID: "lc", sentAt: Date(timeIntervalSince1970: 1000), text: "Hi @Me see https://cmux.dev",
            replyToID: "m0", replyCount: 2, editedAt: Date(timeIntervalSince1970: 1100), editCount: 1,
            reactions: [ConversationReactionMark(participantID: "me", reaction: .heart),
                        ConversationReactionMark(participantID: "aw", reaction: .emoji("🔥"))],
            attachments: [ConversationAttachment(id: "v", kind: .audio, width: 0, height: 0, url: URL(string: "https://example.com/v.m4a"),
                                                 audio: ConversationAudioInfo(duration: 3.5, waveform: [0.1, 0.5], transcript: "hello"))],
            delivery: .read(Date(timeIntervalSince1970: 1200)),
            mentions: [ConversationMention(participantID: "me", location: 3, length: 3)],
            textRuns: [ConversationTextRun(location: 0, length: 2, style: .bold, effect: .shake)],
            links: [ConversationTextLink(location: 11, length: 16, url: URL(string: "https://cmux.dev")!)],
            linkPreview: ConversationLinkPreview(url: URL(string: "https://cmux.dev")!, title: "cmux", state: .loaded),
            effect: .slam,
            poll: ConversationPoll(question: "Ship?", options: [ConversationPollOption(id: "o1", text: "Yes")],
                                   votes: [ConversationPollVote(participantID: "lc", optionID: "o1")]),
            systemEvent: ConversationSystemEvent(kind: .named, name: "cmux")
        )
        let info = ConversationInfo(id: "g", title: "cmux", kind: .group, participants: ScriptedBackend(total: 1).info.participants,
                                    listState: ConversationListState(pinned: true, pinOrder: 1))
        let snapshot = ConversationTranscriptSnapshot(info: info, meID: "me", messages: [message])
        let decoded = try JSONDecoder().decode(ConversationTranscriptSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
    }

    /// A streamed reply changes the transcript many times a second: one file write holds the
    /// newest of them.
    @Test func burstsOfChangesWriteTheNewest() async throws {
        let directory = Self.directory()
        let cache = ConversationTranscriptCache(directory: directory, writeDelay: .milliseconds(200))
        defer { cache.removeAll() }
        let messages = (1...5).map { ConversationMessage(id: "m\($0)", seq: $0, clientMessageID: nil, senderID: "lc",
                                                         sentAt: Date(timeIntervalSince1970: Double($0)), text: "m\($0)") }
        for count in 1...5 { cache.save("k", info: nil, meID: "me", messages: Array(messages.prefix(count))) }
        cache.flush()
        #expect(await ConversationTranscriptCache(directory: directory).load("k")?.messages.count == 5)
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    /// Sign-out while a store shows kept rows: they go, and it keeps nothing more.
    @Test func discardingDropsTheKeptRowsShown() async throws {
        let cache = ConversationTranscriptCache(directory: Self.directory())
        defer { cache.removeAll() }
        _ = try await Self.loadedStore(ScriptedBackend(total: 60), cache: cache, key: "a")
        let shown = ConversationStore(backend: ScriptedBackend(total: 60), pageSize: 30)
        shown.useTranscriptCache(cache, key: "a")
        #expect(shown.messages.count == 30)
        shown.discardKeptTranscript()
        cache.removeAll()
        #expect(shown.messages.isEmpty)
        #expect(!shown.isShowingKeptTranscript)

        // Another key's store drops the first key's kept rows before it shows its own.
        _ = try await Self.loadedStore(ScriptedBackend(total: 60), cache: cache, key: "a")
        let moved = ConversationStore(backend: ScriptedBackend(total: 60), pageSize: 30)
        moved.useTranscriptCache(cache, key: "a")
        #expect(moved.messages.count == 30)
        moved.useTranscriptCache(cache, key: "b")
        #expect(moved.messages.isEmpty)
    }

    /// Sign-out: nothing kept is read again, from memory or disk.
    @Test func removeAllForgetsEverything() async throws {
        let directory = Self.directory()
        let cache = ConversationTranscriptCache(directory: directory)
        _ = try await Self.loadedStore(ScriptedBackend(total: 40), cache: cache, key: "mac:m1")
        cache.flush()
        cache.removeAll()
        cache.flush()
        #expect(cache.cached("mac:m1") == nil)
        #expect(await cache.load("mac:m1") == nil)
        #expect(await ConversationTranscriptCache(directory: directory).load("mac:m1") == nil)
        let store = ConversationStore(backend: ScriptedBackend(total: 40), pageSize: 30)
        store.useTranscriptCache(cache, key: "mac:m1")
        #expect(store.messages.isEmpty)
    }

    /// Two conversations never share kept history (CMUX-281): the JSON files once mapped every
    /// character but ASCII letters, digits and `-` to `_`, so `mac:a.b`, `mac:a/b` and `mac_a_b`
    /// read one file. History is in SQLite now, keyed by the exact conversation key.
    @Test func distinctKeysKeepDistinctHistory() async throws {
        let keys = ["mac:a.b", "mac:a/b", "mac_a_b", "mac:a_b", "mac:a b", "mac:é", "mac:è", "", "_", "default",
                    String(repeating: "x", count: 300), String(repeating: "x", count: 299) + "y"]
        let directory = Self.directory()
        let first = ConversationTranscriptCache(directory: directory, writeDelay: .milliseconds(0))
        for (index, key) in keys.enumerated() { first.save(key, info: nil, meID: "me\(index)", messages: []) }
        first.flush()
        let relaunched = ConversationTranscriptCache(directory: directory)
        defer { relaunched.removeAll() }
        for (index, key) in keys.enumerated() {
            #expect(await relaunched.load(key)?.meID == "me\(index)", "key \(key)")
        }
    }

    /// Kept conversations together stay under the byte limit: after a write, the ones written
    /// longest ago leave first, never the one just written (the user, 2026-11-09: "chats
    /// preserved on disk up to a storage limit, latest kept"). Before, every conversation ever
    /// opened stayed on the phone.
    @Test func theOldestConversationsLeaveAtTheByteLimit() throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let messages = (1...20).map { ConversationMessage(id: "m\($0)", seq: $0, clientMessageID: nil, senderID: "lc",
                                                          sentAt: Date(timeIntervalSince1970: Double($0)), text: "message \($0)") }
        func file(_ key: String) -> URL { directory.appending(path: "\(ConversationTranscriptCache.fileName(for: key)).json") }
        func exists(_ key: String) -> Bool { FileManager.default.fileExists(atPath: file(key).path(percentEncoded: false)) }
        func age(_ key: String, seconds: Double) throws {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)],
                                                  ofItemAtPath: file(key).path(percentEncoded: false))
        }
        // One conversation's size on disk (every key below writes the same bytes).
        let measuring = ConversationTranscriptCache(directory: directory, writeDelay: .milliseconds(0))
        measuring.save("a", info: nil, meID: "me", messages: messages)
        measuring.flush()
        let size = try #require(try file("a").resourceValues(forKeys: [.fileSizeKey]).fileSize)

        // Room for two and a half.
        let cache = ConversationTranscriptCache(directory: directory, byteLimit: size * 5 / 2, writeDelay: .milliseconds(0))
        try age("a", seconds: 1000)
        cache.save("b", info: nil, meID: "me", messages: messages)
        cache.flush()
        #expect(exists("a") && exists("b"))
        try age("b", seconds: 500)
        cache.save("c", info: nil, meID: "me", messages: messages)
        cache.flush()
        #expect(!exists("a"))
        #expect(exists("b") && exists("c"))

        // A limit under one file: the file just written stays.
        let tight = ConversationTranscriptCache(directory: directory, byteLimit: size / 2, writeDelay: .milliseconds(0))
        tight.save("d", info: nil, meID: "me", messages: messages)
        tight.flush()
        #expect(exists("d"))
        #expect(!exists("b") && !exists("c"))
    }
}

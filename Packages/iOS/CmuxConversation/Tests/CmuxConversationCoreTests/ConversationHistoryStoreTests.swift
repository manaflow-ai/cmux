import Foundation
import Testing
@testable import CmuxConversationCore

/// CMUX-24: every Chief conversation's whole history lives on the phone in SQLite, the history
/// UI reads it from there, a cold launch with no network still shows all of it, each account
/// has its own, and a sync that is interrupted, retried or repeated on every reconnect never
/// loses or duplicates a message. Before, the phone kept only the newest 200 messages per
/// conversation (JSON), and older history needed the network.
@MainActor
@Suite(.serialized) struct ConversationHistoryStoreTests {
    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "history-\(UUID().uuidString)")
    }

    static func fetch(_ backend: ScriptedBackend) -> @Sendable (Int?, Int) async throws -> ConversationHistoryPage {
        { try await backend.history(beforeSeq: $0, limit: $1) }
    }

    /// A conversation's history, read whole into the device.
    @Test func aSyncStoresTheWholeHistory() async throws {
        let cache = ConversationTranscriptCache(directory: Self.directory())
        defer { cache.removeAll() }
        cache.activate(account: "user_a")
        let backend = ScriptedBackend(total: 1234)
        let report = try await cache.sync("cloud:c1", pageSize: 100, fetch: Self.fetch(backend))
        #expect(report.range == ConversationHistoryRange(oldestSeq: 1, newestSeq: 1234, complete: true))
        #expect(await cache.storedCount("cloud:c1") == 1234)
        #expect(report.pages == 13)
    }

    /// A cold launch with no network: a new cache over the same folder, a store that never
    /// connects. It shows the newest messages, and scrolling up reads every older one from the
    /// device down to the first.
    @Test func aColdOfflineLaunchReadsTheWholeHistory() async throws {
        let directory = Self.directory()
        let first = ConversationTranscriptCache(directory: directory)
        first.activate(account: "user_a")
        _ = try await first.sync("cloud:c1", pageSize: 100, fetch: Self.fetch(ScriptedBackend(total: 700)))
        first.flush()

        let relaunched = ConversationTranscriptCache(directory: directory)
        defer { relaunched.removeAll() }
        relaunched.activate(account: "user_a")
        let offline = ScriptedBackend(total: 700)
        let store = ConversationStore(backend: offline, pageSize: 50)
        store.useTranscriptCache(relaunched, key: "cloud:c1")
        try await waitUntil { store.messages.count == ConversationTranscriptCache.limit }
        #expect(store.messages.last?.seq == 700)
        #expect(store.isShowingKeptTranscript)
        while store.older != .exhausted {
            let count = store.messages.count
            store.loadOlder()
            try await waitUntil { store.messages.count > count || store.older == .exhausted }
        }
        #expect(store.messages.compactMap(\.seq) == Array(1...700))
        #expect(offline.historyCount == 0)
    }

    /// Online, a page above the loaded window that the device already holds comes from the
    /// device, not the server.
    @Test func olderPagesComeFromTheDeviceOnceSynced() async throws {
        let cache = ConversationTranscriptCache(directory: Self.directory())
        defer { cache.removeAll() }
        cache.activate(account: "user_a")
        let backend = ScriptedBackend(total: 300)
        _ = try await cache.sync("k", pageSize: 100, fetch: Self.fetch(backend))
        let store = ConversationStore(backend: backend, pageSize: 50)
        store.useTranscriptCache(cache, key: "k")
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        let asked = backend.historyCount
        store.loadOlder()
        try await waitUntil { store.messages.count == 100 }
        #expect(store.messages.first?.seq == 201)
        #expect(backend.historyCount == asked)
    }

    /// The network drops during a backfill: what was written stays, the next sync resumes below
    /// it, and no message is stored twice.
    @Test func anInterruptedSyncResumesWithoutLossOrDuplicates() async throws {
        let cache = ConversationTranscriptCache(directory: Self.directory())
        defer { cache.removeAll() }
        cache.activate(account: "user_a")
        let backend = ScriptedBackend(total: 1000)
        let calls = FetchCounter()
        await #expect(throws: ConversationBackendError.self) {
            try await cache.sync("k", pageSize: 100) { before, limit in
                if calls.next() == 4 { throw ConversationBackendError(code: -1, message: "offline") }
                return try await backend.history(beforeSeq: before, limit: limit)
            }
        }
        let partial = try #require(await cache.syncedRange("k"))
        #expect(partial == ConversationHistoryRange(oldestSeq: 701, newestSeq: 1000, complete: false))
        #expect(await cache.storedCount("k") == 300)

        backend.total = 1010
        let report = try await cache.sync("k", pageSize: 100, fetch: Self.fetch(backend))
        #expect(report.range == ConversationHistoryRange(oldestSeq: 1, newestSeq: 1010, complete: true))
        #expect(await cache.storedCount("k") == 1010)
        // The newest page, then only the seven pages below the resume point.
        #expect(report.pages == 8)
    }

    /// Reconnecting again and again: each sync reads only the newest page, and the store holds
    /// every message exactly once.
    @Test func repeatedReconnectsAreIdempotent() async throws {
        let cache = ConversationTranscriptCache(directory: Self.directory())
        defer { cache.removeAll() }
        cache.activate(account: "user_a")
        let backend = ScriptedBackend(total: 250)
        _ = try await cache.sync("k", pageSize: 100, fetch: Self.fetch(backend))
        for round in 1...4 {
            backend.total = 250 + round * 3
            let report = try await cache.sync("k", pageSize: 100, fetch: Self.fetch(backend))
            #expect(report.pages == 1)
            #expect(await cache.storedCount("k") == backend.total)
        }
        // A reconnect with nothing new changes nothing.
        _ = try await cache.sync("k", pageSize: 100, fetch: Self.fetch(backend))
        #expect(await cache.storedCount("k") == 262)
        // A backlog longer than a page while away: caught up in one write, still no gap.
        backend.total = 600
        let report = try await cache.sync("k", pageSize: 100, fetch: Self.fetch(backend))
        #expect(report.pages == 4)
        #expect(report.range == ConversationHistoryRange(oldestSeq: 1, newestSeq: 600, complete: true))
        #expect(await cache.storedCount("k") == 600)
    }

    /// Each account has its own history: another account reads none of it, a sync that began
    /// for one account writes nothing after a switch, and sign-out removes every account's.
    @Test func accountsNeverSeeEachOthersHistory() async throws {
        let directory = Self.directory()
        let cache = ConversationTranscriptCache(directory: directory)
        defer { cache.removeAll() }
        cache.activate(account: "user_a")
        _ = try await cache.sync("cloud:c1", pageSize: 100, fetch: Self.fetch(ScriptedBackend(total: 120)))
        #expect(await cache.load("cloud:c1")?.messages.count == 120)

        cache.activate(account: "user_b")
        #expect(cache.cached("cloud:c1") == nil)
        #expect(await cache.load("cloud:c1") == nil)
        #expect(await cache.storedCount("cloud:c1") == 0)
        // A store showing account A's rows drops them when it moves to account B.
        cache.activate(account: "user_a")
        let shown = ConversationStore(backend: ScriptedBackend(total: 120), pageSize: 50)
        shown.useTranscriptCache(cache, key: "cloud:c1")
        try await waitUntil { shown.messages.count == 120 }
        cache.activate(account: "user_b")
        shown.discardKeptTranscript()
        shown.useTranscriptCache(cache, key: "cloud:c1")
        #expect(shown.messages.isEmpty)

        // A sync that started for B, then the account switched to A: nothing lands anywhere.
        let gate = PreparationGate()
        let backend = ScriptedBackend(total: 500)
        let task = Task { @MainActor in
            try await cache.sync("cloud:c2", pageSize: 100) { before, limit in
                let page = try await backend.history(beforeSeq: before, limit: limit)
                if before != nil { await gate.wait() }
                return page
            }
        }
        try await waitUntil { backend.historyCount >= 2 }
        cache.activate(account: "user_a")
        gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await cache.storedCount("cloud:c2") == 0)
        cache.activate(account: "user_b")
        #expect(await cache.storedCount("cloud:c2") <= 100)

        // Sign-out: every account's file goes.
        cache.removeAll()
        cache.flush()
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
        cache.activate(account: "user_a")
        #expect(await cache.storedCount("cloud:c1") == 0)
    }

    /// The server's history no longer holds what is stored (a reset backend): the stored rows
    /// are replaced, not mixed with the new history.
    @Test func aResetHistoryReplacesWhatIsStored() async throws {
        let cache = ConversationTranscriptCache(directory: Self.directory())
        defer { cache.removeAll() }
        _ = try await cache.sync("k", pageSize: 100, fetch: Self.fetch(ScriptedBackend(total: 300)))
        let report = try await cache.sync("k", pageSize: 100, fetch: Self.fetch(ScriptedBackend(total: 12)))
        #expect(report.replaced)
        #expect(await cache.storedCount("k") == 12)
        #expect(report.range == ConversationHistoryRange(oldestSeq: 1, newestSeq: 12, complete: true))
    }

    /// Delete for me leaves the device for good: a later sync does not bring the row back.
    @Test func deletedForMeStaysDeleted() async throws {
        let cache = ConversationTranscriptCache(directory: Self.directory(), writeDelay: .milliseconds(1))
        defer { cache.removeAll() }
        let backend = ScriptedBackend(total: 80)
        _ = try await cache.sync("k", pageSize: 100, fetch: Self.fetch(backend))
        let store = ConversationStore(backend: backend, pageSize: 100)
        store.useTranscriptCache(cache, key: "k")
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        let doomed = try #require(store.messages.first { $0.seq == 40 })
        store.deleteLocally(rowIDs: [doomed.rowID])
        store.saveTranscript()
        cache.flush()
        #expect(await cache.storedCount("k") == 79)
        _ = try await cache.sync("k", pageSize: 100, fetch: Self.fetch(backend))
        #expect(await cache.storedCount("k") == 79)
        #expect(await cache.older("k", beforeSeq: 41, limit: 1, requireSynced: false)?.messages.first?.seq == 39)
    }

    /// A store's own window widens the synced range it touches, so a conversation read on
    /// screen to its first message counts as stored whole.
    @Test func aStoreReadToTheStartMarksTheHistoryComplete() async throws {
        let cache = ConversationTranscriptCache(directory: Self.directory(), writeDelay: .milliseconds(1))
        defer { cache.removeAll() }
        let backend = ScriptedBackend(total: 60)
        let store = ConversationStore(backend: backend, pageSize: 50)
        store.useTranscriptCache(cache, key: "k")
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        store.loadOlder()
        try await waitUntil { store.older == .exhausted }
        store.saveTranscript()
        cache.flush()
        #expect(await cache.syncedRange("k") == ConversationHistoryRange(oldestSeq: 1, newestSeq: 60, complete: true))
        #expect(await cache.storedCount("k") == 60)
    }
}

/// Counts calls across tasks.
final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

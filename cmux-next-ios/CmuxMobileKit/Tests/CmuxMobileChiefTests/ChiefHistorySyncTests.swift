import CmuxConversationCore
import Foundation
import Testing
@testable import CmuxMobileChief

/// CMUX-24: the phone keeps every Chief conversation's whole history, retries a sync that
/// fails, runs it again on a reconnect that comes while one runs, stops on sign-out, and never
/// shows one account's Chief history to another.
@Suite @MainActor struct ChiefHistorySyncTests {
    static func cache() -> ConversationTranscriptCache {
        ConversationTranscriptCache(directory: FileManager.default.temporaryDirectory
            .appending(path: "chief-history-\(UUID().uuidString)"))
    }

    /// A history of `total` messages, failing its first `failures` reads.
    final class History: @unchecked Sendable {
        private let lock = NSLock()
        private var _total: Int
        private var failures: Int
        private(set) var reads = 0
        init(total: Int, failures: Int = 0) {
            _total = total
            self.failures = failures
        }
        var total: Int {
            get { lock.withLock { _total } }
            set { lock.withLock { _total = newValue } }
        }
        func page(_ before: Int?, _ limit: Int) throws -> ConversationHistoryPage {
            try lock.withLock {
                reads += 1
                if failures > 0 {
                    failures -= 1
                    throw ConversationBackendError(code: -1, message: "offline")
                }
                let upper = (before ?? (_total + 1)) - 1
                guard upper >= 1 else { return ConversationHistoryPage(messages: [], hasMore: false) }
                let lower = max(1, upper - limit + 1)
                return ConversationHistoryPage(messages: (lower...upper).map {
                    ConversationMessage(id: "m\($0)", seq: $0, clientMessageID: nil, senderID: "chief",
                                        sentAt: Date(timeIntervalSince1970: Double($0)), text: "m\($0)")
                }, hasMore: lower > 1)
            }
        }
    }

    @Test func aFailedSyncRetriesThenStoresEverything() async throws {
        let cache = Self.cache()
        defer { cache.removeAll() }
        cache.activate(account: "user_a")
        let sync = ChiefHistorySync(clock: ImmediateClock())
        let history = History(total: 450, failures: 2)
        sync.sync("cloud:c1", cache: cache, pageSize: 100) { try history.page($0, $1) }
        try await waitUntil("the sync") { !sync.isSyncing("cloud:c1") }
        #expect(sync.reports["cloud:c1"]?.range == ConversationHistoryRange(oldestSeq: 1, newestSeq: 450, complete: true))
        #expect(await cache.storedCount("cloud:c1") == 450)
    }

    /// A reconnect while a sync runs (its backend now closed): the new one starts at once and
    /// stores what came meanwhile.
    @Test func aReconnectDuringASyncTakesOverAtOnce() async throws {
        let cache = Self.cache()
        defer { cache.removeAll() }
        cache.activate(account: "user_a")
        let sync = ChiefHistorySync(clock: ImmediateClock())
        let history = History(total: 900)
        var finished = 0
        sync.onFinish = { _, _ in finished += 1 }
        sync.sync("mac:m1", cache: cache, pageSize: 100) { try history.page($0, $1) }
        // New messages, and the phone reconnects while the first sync still runs.
        history.total = 905
        sync.sync("mac:m1", cache: cache, pageSize: 100) { try history.page($0, $1) }
        try await waitUntil("the newer sync") { finished == 1 && !sync.isSyncing("mac:m1") }
        #expect(await cache.storedCount("mac:m1") == 905)
        #expect(sync.reports["mac:m1"]?.range?.newestSeq == 905)
    }

    @Test func signOutStopsEverySync() async throws {
        let cache = Self.cache()
        defer { cache.removeAll() }
        cache.activate(account: "user_a")
        let sync = ChiefHistorySync(clock: ImmediateClock())
        let history = History(total: 100, failures: 1_000)
        sync.sync("cloud:c1", cache: cache, pageSize: 100) { try history.page($0, $1) }
        #expect(sync.isSyncing("cloud:c1"))
        sync.cancelAll()
        #expect(!sync.isSyncing("cloud:c1"))
        #expect(sync.reports.isEmpty)
    }

    /// The Mac and Cloud sessions share one cache: switching accounts drops the kept rows of
    /// both, not only of the session that switched the cache first.
    @Test func bothSessionsSharingACacheDropTheOtherAccountsRows() async throws {
        let cache = Self.cache()
        defer { cache.removeAll() }
        func session() -> ChiefSession {
            ChiefSession(backend: ChiefOfflineBackend(), outbox: ChiefOutbox(file: FileManager.default.temporaryDirectory
                .appendingPathComponent("outbox-\(UUID().uuidString).json")), transcripts: cache)
        }
        let mac = session(), cloud = session()
        mac.useTranscriptAccount("user_a")
        cloud.useTranscriptAccount("user_a")
        for (chief, id) in [(mac, "mac-A"), (cloud, "mac-C")] {
            chief.macID = id
            chief.use(ChiefMockBackend(sleep: { _ in }))
            try await waitUntil("\(id) to load") { chief.store.hasLoadedNewest && !chief.store.messages.isEmpty }
            chief.use(ChiefOfflineBackend())
            #expect(chief.store.isShowingKeptTranscript)
        }
        mac.useTranscriptAccount("user_b")
        cloud.useTranscriptAccount("user_b")
        #expect(mac.store.messages.isEmpty)
        #expect(cloud.store.messages.isEmpty)
    }

    /// The session's kept rows belong to the account: switching accounts drops them at once and
    /// shows only the new account's, and switching back shows the first account's again.
    @Test func anotherAccountNeverSeesTheKeptRows() async throws {
        let cache = Self.cache()
        defer { cache.removeAll() }
        let outbox = ChiefOutbox(file: FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString).json"))
        let session = ChiefSession(backend: ChiefOfflineBackend(), outbox: outbox, transcripts: cache)
        session.useTranscriptAccount("user_a")
        session.macID = "mac-A"
        session.use(ChiefMockBackend(sleep: { _ in }))
        try await waitUntil("Mac A's Chief to load") { session.store.hasLoadedNewest && !session.store.messages.isEmpty }
        let seen = session.store.messages.compactMap(\.seq)
        session.use(ChiefOfflineBackend())
        #expect(session.store.isShowingKeptTranscript)

        session.useTranscriptAccount("user_b")
        #expect(session.store.messages.isEmpty)
        try await waitUntil("account B's (empty) read") { cache.account == "user_b" }
        #expect(session.store.messages.isEmpty)

        session.useTranscriptAccount("user_a")
        try await waitUntil("account A's rows") { session.store.messages.compactMap(\.seq) == seen }
    }
}

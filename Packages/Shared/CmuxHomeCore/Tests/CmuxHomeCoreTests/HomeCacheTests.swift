import Foundation
import Testing
@testable import CmuxHomeCore

/// Persistence like iMessage (plans/cmux-next/home-state-ownership.md
/// section 4): after a relaunch the Home list and an opened conversation show
/// their history at once from the client's own cache, before the owner
/// answers; drafts, scroll anchors and unsent sends survive; the owner's
/// state overwrites the cache when it arrives. Before this, a relaunched
/// HomeStore showed nothing until its source connected, and a send the owner
/// never committed was lost.
@MainActor
@Suite struct HomeCacheTests {
    func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() { await Task.yield() }
    }

    static func cache() -> HomeCache {
        HomeCache(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("home-cache-\(UUID().uuidString)/home.json"))
    }

    static let austin = ConversationID("conv_austin")

    func texts(_ store: HomeStore, _ id: ConversationID) -> [String] {
        store.transcript(for: id).map(\.plainText)
    }

    /// A store that saw the owner, opened Austin's conversation, then quit.
    func lastLaunch(_ cache: HomeCache) async -> ([String], [String]) {
        let store = HomeStore(source: MockHomeSource(options: .immediate), cache: cache, cacheWriteDelay: .zero)
        store.start()
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        await store.open(Self.austin)
        await waitUntil { !store.transcript(for: Self.austin).isEmpty }
        let rows = store.rows.map(\.title)
        let transcript = texts(store, Self.austin)
        store.stop()
        return (rows, transcript)
    }

    @Test func aRelaunchShowsTheListAndTheConversationBeforeTheOwnerAnswers() async {
        let cache = Self.cache()
        let (rows, transcript) = await lastLaunch(cache)
        #expect(!transcript.isEmpty)
        var offline = MockHomeSource.Options.immediate
        offline.startsOnline = false
        let store = HomeStore(source: MockHomeSource(options: offline), cache: cache, cacheWriteDelay: .zero)
        store.start()
        #expect(!store.isOnline)
        #expect(store.rows.map(\.title) == rows, "the Home list shows at once")
        #expect(texts(store, Self.austin) == transcript, "the conversation shows at once")
    }

    @Test func theOwnerOverwritesTheCacheWhenItAnswers() async throws {
        let cache = Self.cache()
        _ = await lastLaunch(cache)
        var snapshot = try #require(cache.load())
        let window = try #require(snapshot.windows[Self.austin])
        let edited = window.map { message in
            var message = message
            message.parts = [.text("stale copy")]
            return message
        }
        snapshot.windows[Self.austin] = edited
        try cache.save(snapshot)
        let store = HomeStore(source: MockHomeSource(options: .immediate), cache: cache, cacheWriteDelay: .zero)
        store.start()
        #expect(texts(store, Self.austin).allSatisfy { $0 == "stale copy" })
        await waitUntil { store.isOnline && !self.texts(store, Self.austin).contains("stale copy") }
        #expect(!texts(store, Self.austin).contains("stale copy"))
        #expect(try #require(cache.load()).windows[Self.austin]?.contains { $0.parts == [.text("stale copy")] } == false,
                "the cache follows the owner")
    }

    @Test func draftsAndScrollAnchorsSurviveARelaunch() async throws {
        let cache = Self.cache()
        let store = HomeStore(source: MockHomeSource(options: .immediate), cache: cache, cacheWriteDelay: .zero)
        store.start()
        await waitUntil { store.isOnline }
        store.setDraft("half a thought", for: Self.austin)
        store.setScrollAnchor(HomeScrollAnchor(message: MessageID("msg_7"), offset: 42), for: Self.austin)
        store.stop()
        let next = HomeStore(source: MockHomeSource(options: .immediate), cache: cache, cacheWriteDelay: .zero)
        next.start()
        #expect(next.draft(for: Self.austin) == "half a thought")
        #expect(next.scrollAnchor(for: Self.austin) == HomeScrollAnchor(message: MessageID("msg_7"), offset: 42))
        next.setDraft("", for: Self.austin)
        next.stop()
        #expect(try #require(cache.load()).drafts[Self.austin] == nil, "a sent or cleared draft leaves the cache")
    }

    /// The app's quit writes the batch at once: a draft typed in the last
    /// quarter second before Quit was lost (the batch waited 250 ms).
    @Test func aFlushWritesTheCoalescedBatchAtOnce() async throws {
        let cache = Self.cache()
        let store = HomeStore(source: MockHomeSource(options: .immediate), cache: cache, cacheWriteDelay: .seconds(3_600))
        store.start()
        await waitUntil { store.isOnline }
        store.setDraft("typed just before Quit", for: Self.austin)
        #expect(cache.load()?.drafts[Self.austin] == nil, "still in the batch")
        store.flushCache()
        #expect(try #require(cache.load()).drafts[Self.austin] == "typed just before Quit")
        #expect(store.isOnline, "a flush does not stop the store")
    }

    @Test func aSendTheOwnerNeverAnsweredSurvivesAndGoesOnceWithItsKey() async throws {
        let cache = Self.cache()
        let key = IdempotencyKey("send-across-relaunch")
        // The last launch logged the send, then quit before any answer.
        _ = await lastLaunch(cache)
        var snapshot = try #require(cache.load())
        snapshot.sends = [HomeCachedSend(key: key, conversation: Self.austin, text: "sent before quitting",
                                         issuedAt: Date(timeIntervalSince1970: 1_791_000_000), failed: false)]
        try cache.save(snapshot)
        let source = MockHomeSource(options: .immediate)
        let store = HomeStore(source: source, cache: cache, cacheWriteDelay: .zero)
        store.start()
        #expect(store.transcript(for: Self.austin).contains { $0.id == key }, "the unsent row shows at once")
        await store.open(Self.austin)
        await waitUntil { store.transcript(for: Self.austin).first { $0.id == key }?.delivery == .committed }
        #expect(store.transcript(for: Self.austin).first { $0.id == key }?.delivery == .committed)
        let page = try await source.snapshot(of: Self.austin, tail: 50)
        #expect(page.messages.filter { $0.clientMessageID == key }.count == 1)
        await waitUntil { (try? cache.load())?.sends.isEmpty == true }
        #expect(try #require(cache.load()).sends.isEmpty, "a committed send leaves the cache")
    }

    @Test func aNotDeliveredSendStaysNotDeliveredAfterARelaunch() async throws {
        let cache = Self.cache()
        let key = IdempotencyKey("failed-before-relaunch")
        _ = await lastLaunch(cache)
        var snapshot = try #require(cache.load())
        snapshot.sends = [HomeCachedSend(key: key, conversation: Self.austin, text: "did not go",
                                         issuedAt: Date(timeIntervalSince1970: 1_791_000_000), failed: true)]
        try cache.save(snapshot)
        var offline = MockHomeSource.Options.immediate
        offline.startsOnline = false
        let store = HomeStore(source: MockHomeSource(options: offline), cache: cache, cacheWriteDelay: .zero)
        store.start()
        let row = try #require(store.transcript(for: Self.austin).first { $0.id == key })
        guard case .notDelivered = row.delivery else {
            Issue.record("expected Not Delivered, got \(row.delivery)")
            return
        }
    }
}

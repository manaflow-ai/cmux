import Foundation
import Testing
import CmuxHomeCoreTestSupport
@testable import CmuxHomeCore

/// A closed chat's transcript stays in the client cache (ui-state-fixes M2), so opening it after
/// a relaunch draws it at once instead of an empty transcript while the owner answers. Before,
/// the cache held only the open windows: a close moved the transcript to memory only
/// (``HomeMirror/endTranscript(_:)``) and the next write removed its file. The closed chats on disk
/// are a least-recently-closed list bounded by count and bytes.
@MainActor
@Suite struct HomeCacheKeptTranscriptTests {
    static let austin = ConversationID("conv_austin")

    @Test func aClosedChatDrawsAtOnceAfterARelaunch() async throws {
        let cache = HomeCacheTests.cache()
        let store = HomeStore(source: MockHomeSource(options: .immediate), cache: cache, cacheWriteDelay: .zero)
        store.start()
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        await store.open(Self.austin)
        let shown = store.transcript(for: Self.austin).map(\.plainText)
        #expect(!shown.isEmpty)
        store.close(Self.austin)
        store.stop()
        await store.flushCache()

        let snapshot = try #require(cache.load())
        #expect(snapshot.windows[Self.austin]?.isEmpty == false, "the closed chat's transcript left the cache")
        #expect(snapshot.keptIDs == [Self.austin])

        var offline = MockHomeSource.Options.immediate
        offline.startsOnline = false
        let next = HomeStore(source: MockHomeSource(options: offline), cache: cache, cacheWriteDelay: .zero)
        next.start()
        // Seeded as a kept transcript, not a live window: nothing is read for it until it opens.
        #expect(next.mirror.windows[Self.austin] == nil)
        next.beginOpen(Self.austin)
        #expect(next.transcript(for: Self.austin).map(\.plainText) == shown, "the closed chat drew empty after a relaunch")
        next.stop()
    }
}

/// The cache's bound on closed chats: newest closed first, at most ``HomeCache/keptLimit`` and
/// ``HomeCache/keptByteLimit``; live windows are not part of it.
@Suite struct HomeCacheKeptBoundTests {
    let author = ParticipantID("user_o")

    func messages(_ conv: ConversationID, text: String = "hi") -> [Message] {
        [Message(id: MessageID("\(conv.rawValue)-m1"), conversation: conv, seq: 1,
                 clientMessageID: IdempotencyKey("\(conv.rawValue)-k1"), author: author,
                 parts: [.text(text)], createdAt: Date(timeIntervalSince1970: 1))]
    }

    @Test func keepsTheNewestClosedChatsWithinTheCount() async throws {
        let cache = await HomeCacheTests.cache()
        let live = ConversationID("conv_live")
        let closed = (0..<(HomeCache.keptLimit + 5)).map { ConversationID("conv_closed_\($0)") }
        var snapshot = HomeCacheSnapshot()
        snapshot.windows[live] = messages(live)
        for id in closed { snapshot.windows[id] = messages(id) }
        snapshot.keptIDs = closed
        try await cache.save(snapshot)

        let loaded = try #require(cache.load())
        let newest = Array(closed.suffix(HomeCache.keptLimit))
        #expect(loaded.keptIDs == newest)
        #expect(Set(loaded.windows.keys) == Set(newest + [live]), "the oldest closed chats outlived the bound")
        let files = try FileManager.default.contentsOfDirectory(at: cache.windowsDirectory, includingPropertiesForKeys: nil)
        #expect(files.count == HomeCache.keptLimit + 1, "an evicted chat's file stayed on disk")
    }

    @Test func keepsTheNewestClosedChatsWithinTheBytes() async throws {
        let cache = await HomeCacheTests.cache()
        // Two of these fit in the byte bound, three do not.
        let big = String(repeating: "x", count: HomeCache.keptByteLimit / 3 + 1)
        let closed = (0..<4).map { ConversationID("conv_big_\($0)") }
        var snapshot = HomeCacheSnapshot()
        for id in closed { snapshot.windows[id] = messages(id, text: big) }
        snapshot.keptIDs = closed
        try await cache.save(snapshot)

        let loaded = try #require(cache.load())
        #expect(loaded.keptIDs == Array(closed.suffix(2)))
        #expect(Set(loaded.windows.keys) == Set(closed.suffix(2)))
    }

    @Test func aSeededClosedChatIsKeptNotLive() {
        let me = Participant(id: ParticipantID("user_me"), kind: .human, displayName: "Me")
        let other = Participant(id: author, kind: .human, displayName: "O")
        let conv = ConversationID("conv_a")
        var snapshot = HomeCacheSnapshot()
        snapshot.me = me
        snapshot.conversations = [ConversationSummary(id: conv, participants: [me, other], lastSeq: 1, rev: 1,
                                                      createdAt: Date(timeIntervalSince1970: 0),
                                                      updatedAt: Date(timeIntervalSince1970: 0))]
        snapshot.windows[conv] = messages(conv)
        snapshot.keptIDs = [conv]
        var mirror = HomeMirror()
        mirror.seed(snapshot)
        #expect(mirror.windows[conv] == nil)
        #expect(mirror.keptTranscripts.map(\.id) == [conv])
        let restored = mirror.restoreKept(conv)
        #expect(restored)
        #expect(mirror.windows[conv]?.messages.map(\.seq) == [1])
    }
}

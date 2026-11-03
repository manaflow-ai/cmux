import Foundation
import Testing
@testable import CmuxHomeCore

/// A Home cache write is proportional to the change (speed-of-sound-DESIGN.md 3.5). Before, every
/// change to the mirror or the log (one live message, one summary update) re-encoded and
/// atomically rewrote one file holding every conversation and up to 200 messages of each opened
/// one, on the main actor: with agents working, about 4 whole-file rewrites a second. Now the
/// windows live in their own files and the `HomeCache` actor rewrites only those that changed.
@Suite struct HomeCacheProportionalWriteTests {
    static let austin = ConversationID("conv_austin")
    static let bob = ConversationID("conv_bob")
    static let author = ParticipantID("agent_chief")

    static let writer = UUID()

    static func cache() -> HomeCache {
        HomeCache(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("home-proportional-\(UUID().uuidString)/home.json"))
    }

    static func messages(_ conversation: ConversationID, count: Int) -> [Message] {
        (1...count).map { seq in
            Message(id: MessageID("\(conversation.rawValue)-m\(seq)"), conversation: conversation, seq: Seq(seq),
                    clientMessageID: IdempotencyKey("\(conversation.rawValue)-k\(seq)"), author: author,
                    parts: [.text("t\(seq)")], createdAt: Date(timeIntervalSince1970: Double(seq)))
        }
    }

    /// An atomic write replaces the file: its inode moves on every write and never otherwise.
    static func inode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.systemFileNumber] as? NSNumber).intValue
    }

    static func windowFile(_ cache: HomeCache, _ id: ConversationID) -> URL {
        cache.windowsDirectory.appendingPathComponent(id.rawValue + ".json")
    }

    @Test func aMessageInOneConversationRewritesOnlyItsWindow() async throws {
        let cache = Self.cache()
        var state = HomeCacheState()
        state.windows = [Self.austin: Self.messages(Self.austin, count: 50),
                         Self.bob: Self.messages(Self.bob, count: 50)]
        #expect(await cache.write(state, sequence: 1, writer: Self.writer))
        let austin = try Self.inode(Self.windowFile(cache, Self.austin))
        let bob = try Self.inode(Self.windowFile(cache, Self.bob))
        let index = try Self.inode(cache.url)

        state.windows[Self.bob] = Self.messages(Self.bob, count: 51)
        #expect(await cache.write(state, sequence: 2, writer: Self.writer))
        #expect(try Self.inode(Self.windowFile(cache, Self.austin)) == austin, "an unchanged window was rewritten")
        #expect(try Self.inode(Self.windowFile(cache, Self.bob)) != bob, "the changed window is written")
        #expect(try Self.inode(cache.url) == index, "the index did not change, so it is not rewritten")

        #expect(await cache.write(state, sequence: 3, writer: Self.writer))
        #expect(try Self.inode(Self.windowFile(cache, Self.austin)) == austin)
        #expect(try Self.inode(cache.url) == index, "an equal state writes nothing")

        let loaded = try #require(cache.load())
        #expect(loaded.windows[Self.bob]?.count == 51)
        #expect(loaded.windows[Self.austin]?.count == 50)
    }

    @Test func aWindowThatLeftIsRemovedAndAnOlderStateIsDropped() async throws {
        let cache = Self.cache()
        var state = HomeCacheState()
        state.windows = [Self.austin: Self.messages(Self.austin, count: 3),
                         Self.bob: Self.messages(Self.bob, count: 3)]
        #expect(await cache.write(state, sequence: 2, writer: Self.writer))
        var newer = state
        newer.windows[Self.austin] = nil
        #expect(await cache.write(newer, sequence: 3, writer: Self.writer))
        #expect(!FileManager.default.fileExists(atPath: Self.windowFile(cache, Self.austin).path))
        // A write that reaches the actor after a newer one (quit flush vs the coalesced write).
        #expect(await cache.write(state, sequence: 1, writer: Self.writer))
        let loaded = try #require(cache.load())
        #expect(loaded.windows.keys.sorted { $0.rawValue < $1.rawValue } == [Self.bob])
        // Another writer (a second store on the same cache) numbers its states apart.
        #expect(await cache.write(state, sequence: 1, writer: UUID()))
        #expect(try #require(cache.load()).windows.count == 2, "another writer's first state was dropped")
    }

    @Test func aWindowKeepsItsNewestMessagesOnly() async throws {
        let cache = Self.cache()
        var state = HomeCacheState()
        state.windows = [Self.austin: Self.messages(Self.austin, count: HomeCache.windowLimit + 30)]
        #expect(await cache.write(state, sequence: 1, writer: Self.writer))
        let window = try #require(cache.load()?.windows[Self.austin])
        #expect(window.count == HomeCache.windowLimit)
        #expect(window.last?.seq == Seq(HomeCache.windowLimit + 30))
    }

    /// An index written whole by an older build (windows inline) still loads; the next write
    /// moves its windows into their files.
    @Test func anIndexWithInlineWindowsStillLoads() async throws {
        let cache = Self.cache()
        var snapshot = HomeCacheSnapshot()
        snapshot.windows = [Self.austin: Self.messages(Self.austin, count: 4)]
        try FileManager.default.createDirectory(at: cache.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: cache.url)
        #expect(cache.load()?.windows[Self.austin]?.count == 4)
        #expect(await cache.write(HomeCacheState(snapshot), sequence: 1, writer: Self.writer))
        #expect(FileManager.default.fileExists(atPath: Self.windowFile(cache, Self.austin).path))
        #expect(cache.load()?.windows[Self.austin]?.count == 4)
    }

    /// Two equal states whose dictionaries were built in different orders (another insertion
    /// history, another capacity) write the index once. Before, the actor compared the encoded
    /// bytes, and `JSONEncoder` writes a non-`String`-keyed dictionary's entries (drafts, scroll
    /// anchors) in hash order, so an equal state rewrote `home.json`.
    @Test func anEqualStateBuiltInAnotherOrderDoesNotRewriteTheIndex() async throws {
        let ids = (0..<64).map { ConversationID("conv_\($0)") }
        var first = HomeCacheState()
        for id in ids {
            first.drafts[id] = "draft \(id.rawValue)"
            first.scroll[id] = HomeScrollAnchor(message: MessageID("\(id.rawValue)-m1"), offset: 3)
        }
        var second = HomeCacheState()
        second.drafts.reserveCapacity(4096)
        second.scroll.reserveCapacity(4096)
        for id in ids.reversed() {
            second.drafts[id] = "draft \(id.rawValue)"
            second.scroll[id] = HomeScrollAnchor(message: MessageID("\(id.rawValue)-m1"), offset: 3)
        }
        #expect(first.drafts == second.drafts && first.scroll == second.scroll)

        let cache = Self.cache()
        #expect(await cache.write(first, sequence: 1, writer: Self.writer))
        let index = try Self.inode(cache.url)
        #expect(await cache.write(second, sequence: 2, writer: Self.writer))
        #expect(try Self.inode(cache.url) == index, "an equal state rewrote the index")
        #expect(cache.load()?.drafts == first.drafts)
    }

    /// A relaunch reads what is on disk before its first write, so that write rewrites nothing
    /// that did not change.
    @Test func aRelaunchedCacheRewritesNoUnchangedWindow() async throws {
        let first = Self.cache()
        var state = HomeCacheState()
        state.windows = [Self.austin: Self.messages(Self.austin, count: 20)]
        #expect(await first.write(state, sequence: 1, writer: Self.writer))
        let austin = try Self.inode(Self.windowFile(first, Self.austin))
        let relaunched = HomeCache(url: first.url)
        state.drafts = [Self.austin: "typed after the relaunch"]
        #expect(await relaunched.write(state, sequence: 1, writer: UUID()))
        #expect(try Self.inode(Self.windowFile(relaunched, Self.austin)) == austin)
        #expect(relaunched.load()?.drafts[Self.austin] == "typed after the relaunch")
    }
}

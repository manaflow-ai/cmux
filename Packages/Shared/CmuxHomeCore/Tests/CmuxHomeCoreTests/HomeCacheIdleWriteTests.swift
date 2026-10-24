import Foundation
import Testing
@testable import CmuxHomeCore

/// Disk writes follow new information, never events (speed-of-sound-DESIGN.md 1 and 3.5): the
/// Home cache file is rewritten only when what it holds changed. Before, every owner event
/// (a typing frame, a connection change, an owner recovery) rebuilt the rows and rewrote the
/// whole cache (every conversation and up to 200 messages of each opened one) 250 ms later,
/// with the same bytes: an idle Home with a chatty owner wrote hundreds of KB a second.
@MainActor
@Suite struct HomeCacheIdleWriteTests {
    static let austin = ConversationID("conv_austin")
    static let chief = ParticipantID("agent_chief")

    static func cache() -> HomeCache {
        HomeCache(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("home-idle-write-\(UUID().uuidString)/home.json"))
    }

    /// The file's inode and modification time: an atomic write replaces the file, so either
    /// moves on every write, and neither moves when nothing is written.
    static func identity(_ cache: HomeCache) throws -> [String] {
        let attributes = try FileManager.default.attributesOfItem(atPath: cache.url.path)
        let inode = try #require(attributes[.systemFileNumber] as? NSNumber)
        let modified = try #require(attributes[.modificationDate] as? Date)
        return [inode.stringValue, String(modified.timeIntervalSinceReferenceDate)]
    }

    @Test func anUnchangedSnapshotIsNotWrittenAgain() throws {
        let cache = Self.cache()
        let view = HomeClientViewCache(cache: cache, writeDelay: .zero, clock: ContinuousClock())
        view.ownerSnapshot = { HomeCacheSnapshot() }
        view.setDraft("hello", for: Self.austin)
        let written = try Self.identity(cache)
        for _ in 0..<5 { view.scheduleWrite() }
        view.flush()
        #expect(try Self.identity(cache) == written, "the same snapshot was written again")
        view.setDraft("hello again", for: Self.austin)
        #expect(try Self.identity(cache) != written, "a changed draft is written")
        #expect(try #require(cache.load()).drafts == [Self.austin: "hello again"])
    }

    @Test func ephemeralOwnerEventsRewriteNothing() throws {
        let cache = Self.cache()
        let store = HomeStore(source: MockHomeSource(options: .immediate), cache: cache, cacheWriteDelay: .zero)
        store.handle(.connection(.online))
        store.setDraft("kept", for: Self.austin)
        let written = try Self.identity(cache)
        for _ in 0..<20 {
            store.handle(.typing(Self.austin, Self.chief, on: true))
            store.handle(.typing(Self.austin, Self.chief, on: false))
            store.handle(.ownerRecovered)
        }
        #expect(try Self.identity(cache) == written, "typing frames and owner recoveries rewrote the cache")
        #expect(try #require(cache.load()).drafts == [Self.austin: "kept"])
    }
}

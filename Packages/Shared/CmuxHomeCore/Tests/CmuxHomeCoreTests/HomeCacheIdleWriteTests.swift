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

    @Test func anUnchangedSnapshotIsNotWrittenAgain() async throws {
        let cache = Self.cache()
        let view = HomeClientViewCache(cache: cache, writeDelay: .zero, clock: ContinuousClock())
        view.ownerState = { HomeCacheState() }
        view.setDraft("hello", for: Self.austin)
        await view.flush()
        let written = try Self.identity(cache)
        for _ in 0..<5 { view.setDraft("hello", for: Self.austin) }
        await view.flush()
        #expect(try Self.identity(cache) == written, "the same snapshot was written again")
        view.setDraft("hello again", for: Self.austin)
        await view.flush()
        #expect(try Self.identity(cache) != written, "a changed draft is written")
        #expect(try #require(cache.load()).drafts == [Self.austin: "hello again"])
    }

    /// The trigger is gone, not only the write: with the app's coalescing delay, typing frames,
    /// connection changes and owner recoveries start no write Task (no main-actor wake 250 ms
    /// later, no snapshot of every conversation built and compared). Before, every one of them
    /// rebuilt the rows and scheduled a write. A change to what the cache holds still schedules one.
    @Test func ephemeralOwnerEventsScheduleNoWrite() async throws {
        let clock = ManualClock()
        let store = HomeStore(source: MockHomeSource(options: .immediate), clock: clock,
                              cache: Self.cache(), cacheWriteDelay: .milliseconds(250))
        let me = Participant(id: ParticipantID("user_me"), kind: .human, displayName: "Me")
        let chief = Participant(id: Self.chief, kind: .agent, displayName: "Chief", agentClass: .chief)
        let summary = ConversationSummary(id: Self.austin, participants: [me, chief], lastSeq: 0, rev: 1,
                                          createdAt: Date(timeIntervalSince1970: 0),
                                          updatedAt: Date(timeIntervalSince1970: 0), pinRank: nil)
        store.handle(.inbox(InboxSnapshot(me: me, conversations: [summary], rev: 1)))
        #expect(store.viewCache.hasPendingWrite, "a new inbox is new information")
        await store.flushCache()
        #expect(!store.viewCache.hasPendingWrite)

        store.handle(.connection(.online))
        for _ in 0..<20 {
            store.handle(.typing(Self.austin, Self.chief, on: true))
            #expect(!store.viewCache.hasPendingWrite, "a typing frame scheduled a cache write")
            store.handle(.typing(Self.austin, Self.chief, on: false))
            store.handle(.ownerRecovered)
        }
        store.handle(.connection(.offline(since: Date())))
        store.handle(.connection(.online))
        #expect(!store.viewCache.hasPendingWrite, "typing, connection changes and owner recoveries scheduled a cache write")

        store.handle(.inbox(InboxSnapshot(me: me, conversations: [], rev: 2)))
        #expect(store.viewCache.hasPendingWrite, "a conversation that left the inbox is new information")
        await store.flushCache()
    }

    @Test func ephemeralOwnerEventsRewriteNothing() async throws {
        let cache = Self.cache()
        let store = HomeStore(source: MockHomeSource(options: .immediate), cache: cache, cacheWriteDelay: .zero)
        store.handle(.connection(.online))
        store.setDraft("kept", for: Self.austin)
        await store.flushCache()
        let written = try Self.identity(cache)
        for _ in 0..<20 {
            store.handle(.typing(Self.austin, Self.chief, on: true))
            store.handle(.typing(Self.austin, Self.chief, on: false))
            store.handle(.ownerRecovered)
        }
        await store.flushCache()
        #expect(try Self.identity(cache) == written, "typing frames and owner recoveries rewrote the cache")
        #expect(try #require(cache.load()).drafts == [Self.austin: "kept"])
    }
}

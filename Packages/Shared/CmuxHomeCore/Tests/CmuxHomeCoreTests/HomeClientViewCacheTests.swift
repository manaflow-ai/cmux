import Foundation
import Testing
@testable import CmuxHomeCore

/// The view cache on its own: drafts and scroll anchors go into every
/// snapshot next to the owner state, writes coalesce until a flush, and a
/// restore takes the snapshot's client state without writing.
@MainActor
@Suite struct HomeClientViewCacheTests {
    static let austin = ConversationID("conv_austin")

    static func cache() -> HomeCache {
        HomeCache(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("home-view-cache-\(UUID().uuidString)/home.json"))
    }

    @Test func aDraftIsWrittenWithTheOwnerStateAndEmptyTextClearsIt() throws {
        let cache = Self.cache()
        let view = HomeClientViewCache(cache: cache, writeDelay: .zero, clock: ContinuousClock())
        var owner = HomeCacheSnapshot()
        owner.drafts = [Self.austin: "owner snapshots never carry drafts"]
        view.ownerSnapshot = { owner }
        view.setDraft("hello", for: Self.austin)
        #expect(try #require(cache.load()).drafts == [Self.austin: "hello"])
        view.setDraft("", for: Self.austin)
        #expect(view.drafts[Self.austin] == nil)
        #expect(try #require(cache.load()).drafts.isEmpty)
    }

    @Test func writesCoalesceUntilAFlush() throws {
        let cache = Self.cache()
        let view = HomeClientViewCache(cache: cache, writeDelay: .seconds(3_600), clock: ContinuousClock())
        let anchor = HomeScrollAnchor(message: MessageID("msg_1"), offset: 12)
        view.setScrollAnchor(anchor, for: Self.austin)
        #expect(cache.load() == nil, "still in the batch")
        view.flush()
        #expect(try #require(cache.load()).scroll == [Self.austin: anchor])
    }

    @Test func aRestoreTakesTheClientStateWithoutWriting() {
        let cache = Self.cache()
        let view = HomeClientViewCache(cache: cache, writeDelay: .zero, clock: ContinuousClock())
        var snapshot = HomeCacheSnapshot()
        snapshot.drafts = [Self.austin: "restored"]
        var ran = false
        view.restore(snapshot) {
            view.scheduleWrite()
            ran = true
        }
        #expect(ran)
        #expect(view.drafts[Self.austin] == "restored")
        #expect(cache.load() == nil, "a restore writes nothing")
    }
}

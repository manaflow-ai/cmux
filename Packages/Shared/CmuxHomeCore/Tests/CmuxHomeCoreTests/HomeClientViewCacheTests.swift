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

<<<<<<< HEAD
    @Test func aDraftIsWrittenWithTheOwnerStateAndEmptyTextClearsIt() async throws {
        let cache = Self.cache()
        let view = HomeClientViewCache(cache: cache, writeDelay: .zero, clock: ContinuousClock())
        var owner = HomeCacheState()
        owner.drafts = [Self.austin: "owner state never carries drafts"]
        view.ownerState = { owner }
        view.setDraft("hello", for: Self.austin)
        await view.flush()
        #expect(try #require(cache.load()).drafts == [Self.austin: "hello"])
        view.setDraft("", for: Self.austin)
        await view.flush()
=======
    @Test func aDraftIsWrittenWithTheOwnerStateAndEmptyTextClearsIt() throws {
        let cache = Self.cache()
        let view = HomeClientViewCache(cache: cache, writeDelay: .zero, clock: ContinuousClock())
        var owner = HomeCacheSnapshot()
        owner.drafts = [Self.austin: "owner snapshots never carry drafts"]
        view.ownerSnapshot = { owner }
        view.setDraft("hello", for: Self.austin)
        #expect(try #require(cache.load()).drafts == [Self.austin: "hello"])
        view.setDraft("", for: Self.austin)
>>>>>>> origin/main
        #expect(view.drafts[Self.austin] == nil)
        #expect(try #require(cache.load()).drafts.isEmpty)
    }

<<<<<<< HEAD
    @Test func writesCoalesceUntilAFlush() async throws {
=======
    @Test func writesCoalesceUntilAFlush() throws {
>>>>>>> origin/main
        let cache = Self.cache()
        let view = HomeClientViewCache(cache: cache, writeDelay: .seconds(3_600), clock: ContinuousClock())
        let anchor = HomeScrollAnchor(message: MessageID("msg_1"), offset: 12)
        view.setScrollAnchor(anchor, for: Self.austin)
        #expect(cache.load() == nil, "still in the batch")
<<<<<<< HEAD
        await view.flush()
        #expect(try #require(cache.load()).scroll == [Self.austin: anchor])
    }

    @Test func aRestoreTakesTheClientStateWithoutWriting() async {
=======
        view.flush()
        #expect(try #require(cache.load()).scroll == [Self.austin: anchor])
    }

    @Test func aRestoreTakesTheClientStateWithoutWriting() {
>>>>>>> origin/main
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
<<<<<<< HEAD
        await view.flush()
        #expect(cache.load() == nil, "a restore writes nothing")
    }

    /// The Chief Home showed last (CMUX-571): written with the next batch, restored by the next
    /// launch's store before the owner answers, and the same Chief again writes nothing.
    @Test func theLastChiefIsKeptForTheNextLaunch() async throws {
        let cache = Self.cache()
        let view = HomeClientViewCache(cache: cache, writeDelay: .zero, clock: ContinuousClock())
        view.setChief(Self.austin)
        await view.flush()
        #expect(try #require(cache.load()).chief == Self.austin)
        view.setChief(Self.austin)
        #expect(!view.hasPendingWrite)
        let next = HomeClientViewCache(cache: cache, writeDelay: .zero, clock: ContinuousClock())
        next.restore(try #require(cache.load())) {}
        #expect(next.chief == Self.austin)
    }

    /// A cache written before the Chief was kept decodes, with no Chief.
    @Test func aCacheFromBeforeTheChiefHasNone() throws {
        let data = Data(#"{"version":1,"conversations":[],"windows":[],"sends":[],"drafts":[],"scroll":[]}"#.utf8)
        let snapshot = try JSONDecoder().decode(HomeCacheSnapshot.self, from: data)
        #expect(snapshot.chief == nil)
    }
=======
        #expect(cache.load() == nil, "a restore writes nothing")
    }
>>>>>>> origin/main
}

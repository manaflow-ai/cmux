import CmuxMobileAgentChat
import CmuxMobileDesign
import Foundation
import Testing
@testable import CmuxMobileLive

/// Leo, 2026-11-25: "And just be able to still like interact with the rest of the app with that
/// saved copy and whatnot. And I can't connect to the app right now and the placeholder's also
/// bad". A chat whose Mac can't be reached keeps showing the turns this phone saved, and past the
/// quiet bound its title says how old they are ("Mac offline · updated 3 min ago"), as the
/// terminal page's pill does. Never a loading state over a chat the phone holds.
@MainActor
@Suite(.timeLimit(.minutes(2))) struct ChatSavedCopyOfflineTests {
    typealias Kept = AgentKeptTranscriptTests
    typealias Long = LongChatOpenLiveTests

    @Test func theAgePhraseRoundsDownToItsUnit() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        #expect(SavedCopyAge.phrase(since: now, now: now) == "updated just now")
        #expect(SavedCopyAge.phrase(since: now.addingTimeInterval(30), now: now) == "updated just now", "a clock skew is not negative")
        #expect(SavedCopyAge.phrase(since: now.addingTimeInterval(-59), now: now) == "updated just now")
        #expect(SavedCopyAge.phrase(since: now.addingTimeInterval(-60), now: now) == "updated 1 min ago")
        #expect(SavedCopyAge.phrase(since: now.addingTimeInterval(-3599), now: now) == "updated 59 min ago")
        #expect(SavedCopyAge.phrase(since: now.addingTimeInterval(-3600), now: now) == "updated 1 h ago")
        #expect(SavedCopyAge.phrase(since: now.addingTimeInterval(-86_400 * 2), now: now) == "updated 2 d ago")
    }

    /// A chat read live, then reopened with no link (a relaunch offline): the kept copy carries
    /// when it was last the Mac's, the rows show at once, nothing for the quiet bound, then the
    /// title's line with the copy's age.
    @Test func anOfflineReopenShowsTheKeptTurnsAndTheirAge() async throws {
        let directory = Kept.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = Kept.cache(directory)
        let before = Date()
        do {
            let hub = Kept.hub(cache)
            await hub.bind(try await Long.fakeAcpmux((0..<3).flatMap(Long.turnRecords), Long.Requests())
                .openChannel(service: "acpmux", args: [:]))
            let store = AgentChatStore(source: hub.source(sessionID: "s1", summary: Kept.summary))
            await Long.waitUntil { store.turns.last?.id == "t2" && !store.isLoadingHistory }
            #expect(store.offlineLine() == nil, "live: the title keeps its usual words")
        }
        cache.flush()
        let key = try #require(AgentTranscriptCache.key(accountID: "acct", macID: "mac1", tabID: "s7"))
        let savedAt = try #require(cache.cached(key)?.savedAt, "the kept copy is dated")
        #expect(savedAt >= before && savedAt <= Date())

        // Relaunch with no link: a fresh cache reads the file.
        let source = Kept.hub(Kept.cache(directory)).source(sessionID: "s1", summary: Kept.summary)
        let restored = try #require(source.savedCopyAt)
        #expect(abs(restored.timeIntervalSince(savedAt)) < 0.001)

        let store = AgentChatStore(source: source, quietStatus: QuietStatusGate(delay: .milliseconds(300)))
        await Long.waitUntil { store.turns.count == 3 }
        #expect(store.offlineLine() == nil, "nothing during the quiet bound")
        await Long.waitUntil { store.quietStatus.isShown }
        #expect(store.turns.map(\.id) == ["t0", "t1", "t2"], "the saved copy stays readable")
        #expect(!store.isNewChat)
        #expect(store.offlineLine(now: savedAt.addingTimeInterval(180)) == "Mac offline · updated 3 min ago")
    }

    /// A copy kept before it was dated still shows, and its line says only that the Mac is offline.
    @Test func aCopyKeptWithoutADateSaysOnlyOffline() async throws {
        let directory = Kept.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try #require(AgentTranscriptCache.key(accountID: "acct", macID: "mac1", tabID: "s7"))
        let writer = Kept.cache(directory)
        writer.save(key, sessionID: "s1", earlier: false, records: Kept.json((0..<2).flatMap(Long.turnRecords)))
        writer.flush()

        let source = Kept.hub(Kept.cache(directory)).source(sessionID: "s1", summary: Kept.summary)
        #expect(source.savedCopyAt == nil)
        let store = AgentChatStore(source: source, quietStatus: QuietStatusGate(delay: .milliseconds(20)))
        await Long.waitUntil { store.turns.count == 2 && store.quietStatus.isShown }
        #expect(store.offlineLine() == "Mac offline")
    }
}

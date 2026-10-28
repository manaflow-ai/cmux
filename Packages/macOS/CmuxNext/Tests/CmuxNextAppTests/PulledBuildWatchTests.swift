import Foundation
@testable import CmuxNextUpdater
import Testing

/// The pulled-build banner (nightly train, section 2): when the feed's pulled.json lists the
/// running build, the update notice offers "Wait for the Fix" (the default) and, only when the
/// kept build can take over, "Roll Back".
@MainActor @Suite(.serialized) struct PulledBuildWatchTests {
    private static let next = "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml"
    private static let legacy = "https://files-next.cmux.com/nightly-next/appcast-arm64.xml"

    private final class Calls: @unchecked Sendable {
        var rolledBackTo: [String] = []
        /// Times Roll Back asked, and the answer the next question gets (true: Roll Back, false: Cancel).
        var asked = 0
        var confirms = true
    }

    private static func body(_ builds: [(String, String)]) -> Data {
        let entries = builds.map { ["build": $0.0, "reason": $0.1, "pulledAt": "2026-10-20T21:00:00Z", "serve": "100"] }
        return try! JSONSerialization.data(withJSONObject: entries)
    }

    private static func watch(build: String = "300", feed: String = next, list: Data?, kept: KeptVersion? = nil,
                              rollBackFailure: String? = nil, calls: Calls = Calls(), asks: Bool = true,
                              defaults: UserDefaults = UserDefaults(suiteName: "PulledBuildWatchTests.\(UUID().uuidString)")!) -> PulledBuildWatch {
        let watch = PulledBuildWatch(build: build, defaults: defaults, feedURL: { feed },
                                     fetch: { url in url.path.hasSuffix("/next/pulled.json") ? list : nil },
                                     rollbackCheck: { _ in kept },
                                     rollBack: { build, _ in calls.rolledBackTo.append(build); return rollBackFailure })
        // The App's confirmation presenter for updates.rollback, answered by `calls.confirms`.
        if asks {
            watch.confirmRollBack = { proceed in
                calls.asked += 1
                if calls.confirms { proceed() }
            }
        }
        return watch
    }

    private static let kept = KeptVersion(build: "200", shortVersion: "1.0.0-nightly.200", bundle: URL(fileURLWithPath: "/tmp/kept.app"),
                                          storeSchemas: [:], teamID: "TEAM")

    @Test func listURLsSitNextToTheAppcastAndTheLegacyFeedAlsoReadsNext() {
        #expect(PulledBuild.listURLs(feedURL: Self.next).map(\.absoluteString) == ["https://files-next.cmux.com/nightly-next/next/pulled.json"])
        #expect(PulledBuild.listURLs(feedURL: Self.legacy).map(\.absoluteString) == [
            "https://files-next.cmux.com/nightly-next/pulled.json", "https://files-next.cmux.com/nightly-next/next/pulled.json",
        ])
        #expect(PulledBuild.listURLs(feedURL: "http://example.com/appcast.xml").isEmpty)
    }

    @Test func decodeSkipsBadEntries() {
        let data = Data(#"[{"build":"5","reason":"r"},{"reason":"no build"},7]"#.utf8)
        #expect(PulledBuild.decode(data) == [PulledBuild(build: "5", reason: "r")])
        #expect(PulledBuild.decode(Data("nope".utf8)).isEmpty)
    }

    @Test func aPulledBuildWithAKeptBuildOffersWaitFirstThenRollBack() async {
        let watch = Self.watch(list: Self.body([("300", "crashes at launch")]), kept: Self.kept)
        await watch.refresh().value

        #expect(watch.card == .pulled(reason: "crashes at launch", rollbackVersion: "1.0.0-nightly.200"))
        let shown = watch.card?.presentation(version: "1.0.0-nightly.300", build: "300")
        #expect(shown?.actions == [.waitForFix, .rollBack])
        #expect(UpdateCardAction.waitForFix.isProminent)
        #expect(!UpdateCardAction.rollBack.isProminent)
    }

    @Test func withNothingKeptOnlyWaitShows() async {
        let watch = Self.watch(list: Self.body([("300", "bad")]), kept: nil)
        await watch.refresh().value

        #expect(watch.card?.presentation(version: "x", build: "300").actions == [.waitForFix])
    }

    @Test func aBuildNotOnTheListShowsNothing() async {
        let watch = Self.watch(list: Self.body([("299", "older")]), kept: Self.kept)
        await watch.refresh().value
        #expect(watch.card == nil)
        // The Updated card still learns every pulled build, so it never counts one as newer.
        #expect(watch.pulledBuilds == ["299"])

        let missing = Self.watch(list: nil, kept: Self.kept)
        await missing.refresh().value
        #expect(missing.card == nil)
    }

    @Test func waitHidesTheBannerForThatBuildAcrossLaunches() async {
        let defaults = UserDefaults(suiteName: "PulledBuildWatchTests.\(UUID().uuidString)")!
        let watch = Self.watch(list: Self.body([("300", "bad")]), kept: Self.kept, defaults: defaults)
        await watch.refresh().value
        watch.perform(.waitForFix)
        #expect(watch.card == nil)

        let relaunched = Self.watch(list: Self.body([("300", "bad")]), kept: Self.kept, defaults: defaults)
        await relaunched.refresh().value
        #expect(relaunched.card == nil)
    }

    @Test func rollBackRunsTheDropBackToTheKeptBuildAndShowsAFailure() async {
        let calls = Calls()
        let watch = Self.watch(list: Self.body([("300", "bad")]), kept: Self.kept, rollBackFailure: "a store is too new", calls: calls)
        await watch.refresh().value

        watch.perform(.rollBack)
        watch.perform(.rollBack) // a second press while one runs is ignored
        for _ in 0..<50 where watch.rollbackFailure == nil { await Task.yield() }

        #expect(calls.asked == 1)
        #expect(calls.rolledBackTo == ["200"])
        #expect(watch.card == .pulled(reason: "a store is too new", rollbackVersion: "1.0.0-nightly.200"))
    }

    /// Roll Back quits into the kept build (`updates.rollback` is destructive), so it asks first:
    /// Cancel runs nothing and leaves the banner as it was; a later confirmed press still runs.
    @Test func rollBackAsksFirstAndCancelLeavesTheBanner() async {
        let calls = Calls()
        calls.confirms = false
        let watch = Self.watch(list: Self.body([("300", "bad")]), kept: Self.kept, calls: calls)
        await watch.refresh().value
        let shown = watch.card

        watch.perform(.rollBack)
        for _ in 0..<50 { await Task.yield() }
        #expect(calls.asked == 1)
        #expect(calls.rolledBackTo.isEmpty)
        #expect(watch.card == shown)
        #expect(watch.rollbackFailure == nil)

        calls.confirms = true
        watch.perform(.rollBack)
        for _ in 0..<50 where calls.rolledBackTo.isEmpty { await Task.yield() }
        #expect(calls.asked == 2)
        #expect(calls.rolledBackTo == ["200"])
    }

    /// With nobody to ask (no App presenter wired), Roll Back never runs.
    @Test func rollBackWithNobodyToAskRunsNothing() async {
        let calls = Calls()
        let watch = Self.watch(list: Self.body([("300", "bad")]), kept: Self.kept, calls: calls, asks: false)
        await watch.refresh().value

        watch.perform(.rollBack)
        for _ in 0..<50 { await Task.yield() }
        #expect(calls.rolledBackTo.isEmpty)
        #expect(watch.card == .pulled(reason: "bad", rollbackVersion: "1.0.0-nightly.200"))
    }
}

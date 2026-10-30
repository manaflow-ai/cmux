import Foundation
@testable import CmuxNextUpdater
import Testing

/// A pulled build is never offered, kept or installed, and nothing asks about it (Leo 2026-10-29:
/// "why the fuck am I even getting a thing that I can download that I can just— that was pulled in
/// the first place? Just fucking cancel it, or, like, do something else about it. Just don't have
/// that be the downloading thing."). Build 4091813159501 was staged on his Mac, then pulled, and
/// the app showed "This Nightly Was Pulled" with Wait for the Fix and Roll Back. Now the staged
/// pulled build is dropped quietly and the newest good build downloads; a running pulled build
/// downloads the newest good one, and one line says why.
@MainActor @Suite(.serialized) struct PulledBuildWatchTests {
    typealias Base = UpdateStagedYieldsToNewerTests
    private static let next = "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml"
    private static let legacy = "https://files-next.cmux.com/nightly-next/appcast-arm64.xml"

    private static func body(_ builds: [(String, String)]) -> Data {
        let entries = builds.map { ["build": $0.0, "reason": $0.1, "pulledAt": "2026-10-20T21:00:00Z", "serve": "100"] }
        return try! JSONSerialization.data(withJSONObject: entries)
    }

    private static func watch(build: String = "300", feed: String = next, list: Data?) -> PulledBuildWatch {
        PulledBuildWatch(build: build, feedURL: { feed },
                         fetch: { url in url.path.hasSuffix("/next/pulled.json") ? list : nil })
    }

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

    @Test func theWatchReadsTheListAndTheRunningBuildsEntry() async {
        let watch = Self.watch(list: Self.body([("300", "crashes at launch"), ("299", "older")]))
        var refreshed = 0
        watch.onRefresh = { refreshed += 1 }
        await watch.refresh().value
        #expect(watch.pulled?.build == "300")
        #expect(watch.pulledBuilds == ["300", "299"])
        #expect(watch.isPulled("299") && !watch.isPulled("301"))
        #expect(refreshed == 1)

        // A failed read keeps what the last read knew.
        watch.fetch = { _ in nil }
        await watch.refresh().value
        #expect(watch.pulledBuilds == ["300", "299"] && watch.pulled?.build == "300")
        #expect(refreshed == 2)

        // The legacy feed reads two lists: one that answers empty while the other fails forgets nothing.
        let pulledList = Self.body([("300", "bad")]), emptyList = Self.body([])
        let legacyFeed = Self.legacy
        let legacy = PulledBuildWatch(build: "300", feedURL: { legacyFeed }, fetch: { url in
            url.path.hasSuffix("/next/pulled.json") ? pulledList : emptyList
        })
        await legacy.refresh().value
        legacy.fetch = { url in url.path.hasSuffix("/next/pulled.json") ? nil : emptyList }
        await legacy.refresh().value
        #expect(legacy.isPulled("300") && legacy.pulled?.build == "300")

        let missing = Self.watch(list: nil)
        await missing.refresh().value
        #expect(missing.pulled == nil && missing.pulledBuilds.isEmpty)
    }

    /// The staged build (300) was pulled: its installer is cancelled and this app's check fetches
    /// the newest good build; when it is found it downloads with no click, and no card shows.
    @Test func aPulledStagedBuildIsDroppedQuietlyAndTheNewestDownloads() async throws {
        let h = Base.make(ring: "nightly", replaceable: false, pulled: ["300"])
        var downloads = 0
        h.updater.acceptAvailable = { downloads += 1 }
        await h.updater.pulledWatch.refresh().value
        #expect(h.sparkle.cancels == 1, "pulled build 300 stayed staged")
        #expect(h.sparkle.backgroundChecks == 1, "nothing looked for the newest good build")
        #expect(h.updater.newestFetch == .stagedPulled)

        h.sparkle.staged = nil
        for phase: UpdateIndicatorPhase in [.hidden, .checking] {
            h.updater.debugIndicatorPhase = phase
            #expect(h.updater.card == nil, "the quiet swap showed \(String(describing: h.updater.card))")
        }
        h.updater.debugIndicatorPhase = .available(version: "4.0.0")
        #expect(downloads == 1, "the newest good build waits for a click")
        h.updater.debugIndicatorPhase = .downloading(.starting)
        #expect(h.updater.card == nil)
        h.sparkle.staged = "400"
        h.updater.debugIndicatorPhase = .ready(version: "4.0.0")
        #expect(h.updater.newestFetch == nil)
        #expect(h.updater.readyCard != nil, "the newest good build does not ask to restart")

        // A later read of the list changes nothing: 400 is not pulled.
        await h.updater.pulledWatch.refresh().value
        #expect(h.sparkle.cancels == 1 && h.sparkle.backgroundChecks == 1)
    }

    /// With downloads asking first, a cached appcast offers the pulled build again on the update-found
    /// step: it shows no card and no Update Available button, never downloads, and its Sparkle prompt
    /// ends. A found build the list marks pulled later leaves the step the same way.
    @Test func aFoundPulledBuildIsNeverOfferedOrDownloaded() async throws {
        let h = Base.make(ring: "nightly", replaceable: false, pulled: ["300"])
        var downloads = 0, dismissals = 0
        var found: String? = "300"
        h.updater.acceptAvailable = { downloads += 1 }
        h.updater.availableBuild = { found }
        h.updater.dismissAvailable = { dismissals += 1 }
        await h.updater.pulledWatch.refresh().value
        #expect(h.updater.newestFetch == .stagedPulled)

        h.sparkle.staged = nil
        for phase: UpdateIndicatorPhase in [.hidden, .checking, .available(version: "3.0.0")] {
            h.updater.debugIndicatorPhase = phase
        }
        #expect(downloads == 0, "pulled build 300 downloaded again")
        #expect(h.updater.card == nil && h.updater.availableButton == nil, "pulled build 300 was offered")
        #expect(dismissals >= 1, "pulled build 300's prompt stayed open")
        #expect(h.updater.newestFetch == nil)

        // Build 400 waits for a click; then the list marks it pulled.
        found = "400"
        h.updater.debugIndicatorPhase = .hidden
        h.updater.debugIndicatorPhase = .available(version: "4.0.0")
        #expect(h.updater.availableButton != nil)
        let list = Self.body([("300", "crashed"), ("400", "crashed")])
        h.updater.pulledWatch.fetch = { _ in list }
        await h.updater.pulledWatch.refresh().value
        h.updater.downloadClicked()
        #expect(downloads == 0, "pulled build 400 downloaded")
        #expect(h.updater.card == nil && h.updater.availableButton == nil, "pulled build 400 was offered")
    }

    /// A feed that stages the pulled build again (a cached appcast) never loops: it is dropped, and
    /// nothing checks again until Sparkle's next scheduled check.
    @Test func aPulledBuildStagedAgainIsDroppedWithoutAnotherCheck() async throws {
        let h = Base.make(ring: "nightly", pulled: ["300"])
        await h.updater.pulledWatch.refresh().value
        h.updater.debugIndicatorPhase = .checking
        h.updater.debugIndicatorPhase = .downloading(.starting)
        h.updater.debugIndicatorPhase = .ready(version: "3.0.0")
        #expect(h.sparkle.cancels == 2)
        #expect(h.sparkle.backgroundChecks == 1, "the pulled build was fetched again and again")
    }

    /// The running build (100) was pulled: the newest good build is fetched and downloads, the
    /// card says so in one line with no button, and the Update Ready card asks before the relaunch.
    @Test func aPulledRunningBuildUpdatesToTheNewestInOneLine() async throws {
        let h = Base.make(ring: "nightly", replaceable: false, pulled: ["100"])
        var downloads = 0
        h.updater.acceptAvailable = { downloads += 1 }
        h.sparkle.staged = nil
        h.updater.debugIndicatorPhase = .hidden
        await h.updater.pulledWatch.refresh().value
        #expect(h.sparkle.backgroundChecks == 1, "the pulled running build looked for nothing newer")
        #expect(h.sparkle.cancels == 0)
        #expect(h.updater.card == .gettingNewest(nil, pulled: true))
        let shown = try #require(h.updater.cardPresentation)
        #expect(shown.title == UpdaterStrings.gettingNewest)
        #expect(shown.detail == UpdaterStrings.runningBuildPulled)
        #expect(shown.actions.isEmpty && shown.lines.isEmpty, "the pulled build still offers \(shown.actions)")

        h.updater.debugIndicatorPhase = .checking
        h.updater.debugIndicatorPhase = .available(version: "3.0.0")
        #expect(downloads == 1)
        h.sparkle.staged = "300"
        h.updater.debugIndicatorPhase = .ready(version: "3.0.0")
        #expect(h.updater.card == nil)
        #expect(h.updater.readyCard != nil)

        // Once per launch: a later read of the list starts nothing.
        h.sparkle.staged = nil
        h.updater.debugIndicatorPhase = .hidden
        await h.updater.pulledWatch.refresh().value
        #expect(h.sparkle.backgroundChecks == 1)
    }

    /// The running build (100) and the staged build (300) are both pulled, and the staged
    /// installer is not this app's to cancel: the running build still looks for the newest good
    /// build, once.
    @Test func aPulledRunningBuildStillUpdatesWhenAPulledStagedBuildCannotBeDropped() async throws {
        let h = Base.make(ring: "nightly", pulled: ["100", "300"])
        h.updater.cancelStaged = { false }
        await h.updater.pulledWatch.refresh().value
        #expect(h.sparkle.backgroundChecks == 1, "the app stays on pulled build 100")
        #expect(h.updater.newestFetch == .runningPulled)
        h.updater.newestFetch = nil
        await h.updater.pulledWatch.refresh().value
        #expect(h.sparkle.backgroundChecks == 1, "the pulled running build looked twice")
    }

    @Test func aPulledBuildDoesNotDownloadFromAnOffManagedChannel() async {
        let h = Base.make(ring: "nightly", pulled: ["100", "300"])
        h.updater.applyManagedPolicy(channel: "stable", minimumVersion: nil)
        var downloads = 0
        h.updater.acceptAvailable = { downloads += 1 }
        await h.updater.pulledWatch.refresh().value
        #expect(h.sparkle.cancels == 1, "the pulled installer must still be cancelled")
        #expect(h.sparkle.backgroundChecks == 0, "automatic recovery checked the forbidden nightly channel")
        h.sparkle.staged = nil
        h.updater.debugIndicatorPhase = .hidden
        await h.updater.pulledWatch.refresh().value
        h.updater.debugIndicatorPhase = .available(version: "4.0.0")
        #expect(downloads == 0, "automatic recovery downloaded from the forbidden nightly channel")
        #expect(h.updater.newestFetch == nil)
    }

    @Test func aPulledRunningAndStagedBuildKeepsTheRunningExplanation() async {
        let h = Base.make(ring: "nightly", pulled: ["100", "300"])
        await h.updater.pulledWatch.refresh().value
        #expect(h.sparkle.cancels == 1)
        #expect(h.sparkle.backgroundChecks == 1)
        #expect(h.updater.newestFetch == .runningPulled)
        h.sparkle.staged = nil
        h.updater.debugIndicatorPhase = .checking
        #expect(h.updater.card == .gettingNewest(nil, pulled: true))
        #expect(h.updater.cardPresentation?.detail == UpdaterStrings.runningBuildPulled)
    }

    /// With nothing newer than the pulled running build on the feed, the check ends and nothing shows.
    @Test func aPulledRunningBuildWithNothingNewerEndsQuietly() async throws {
        let h = Base.make(ring: "nightly", pulled: ["100"])
        h.sparkle.staged = nil
        h.updater.debugIndicatorPhase = .hidden
        await h.updater.pulledWatch.refresh().value
        h.updater.debugIndicatorPhase = .checking
        h.updater.debugIndicatorPhase = .hidden
        #expect(h.updater.newestFetch == nil)
        #expect(h.updater.card == nil)
    }
}

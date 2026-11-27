@testable import CmuxNextUpdater
import Foundation
import Testing

/// "i had to click restart to update, then it restarted, then restart to update prompt appeared
/// again" (Lawrence 2026-10-23; also 2026-10-22, msg 10103). The system log of that night: a
/// nightly was staged at 02:10, the next nightly (3993193180601) was published at 03:37, the click
/// at 03:39 installed the build staged at 02:10, and 13 s after the relaunch the new app found
/// 3993193180601 and staged it: a second "Restart to Update". The staged update was read against
/// the feed only once an hour (``StagedUpdateRefresh``) and never at the click. Now the click reads
/// the feed first (bounded), and a newer build of the ring replaces the staged one: one click ends
/// on the newest build.
@MainActor @Suite(.serialized) struct UpdateClickInstallsNewestTests {
    typealias Base = UpdateStagedYieldsToNewerTests

    /// Nightly 300 (staged) and, when `newer`, nightly 500 published 2 minutes ago (no deltas yet).
    static func feed(newer: Bool) -> String {
        let fresh = newer
            ? "<item><title>nightly 500</title><sparkle:version>500</sparkle:version><pubDate>\(Base.pubDate(minutesAgo: 2))</pubDate><sparkle:channel>cmux-next</sparkle:channel></item>"
            : ""
        return """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>cmux NEXT</title>
        <item><title>nightly</title><sparkle:version>300</sparkle:version><pubDate>\(Base.pubDate(minutesAgo: 90))</pubDate><sparkle:channel>cmux-next</sparkle:channel></item>
        \(fresh)
        </channel></rss>
        """
    }

    /// The harness with the install seams counted.
    final class Installs {
        var count = 0
        var downloads = 0
    }

    /// The harness with the install seams counted. `downloadsAsk`: found updates wait for a click
    /// (`updates.downloadAutomatically` off, the nightly default); `cancellable`: this app's driver
    /// holds the staged installer; `pulled`: pulled.json's builds.
    static func make(newer: Bool, held: Bool = false, downloadsAsk: Bool = false, cancellable: Bool = true,
                     pulled: [String] = []) -> (Base.Harness, Installs) {
        let h = Base.make(ring: "nightly", feed: feed(newer: newer), held: held, replaceable: !downloadsAsk,
                          cancellable: cancellable, pulled: pulled)
        let installs = Installs()
        h.updater.preflightOverride = { nil }
        h.updater.installStaged = { installs.count += 1 }
        h.updater.acceptAvailable = { installs.downloads += 1 }
        return (h, installs)
    }

    func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    @Test func oneClickInstallsTheNewestBuildNotTheStaleStagedOne() async throws {
        let (h, installs) = Self.make(newer: true)
        h.updater.installClicked()
        #expect(await eventually { h.sparkle.cancels == 1 }, "the click kept stale staged build 300 though 500 is out")
        #expect(h.sparkle.backgroundChecks == 1, "nothing downloads build 500")
        #expect(installs.count == 0, "the click installed stale build 300: the relaunch offers Restart to Update again")

        // Sparkle drops 300, finds 500, downloads and stages it; the click carries over.
        h.sparkle.staged = "500"
        for phase: UpdateIndicatorPhase in [.hidden, .checking, .downloading(.starting),
                                            .downloading(.downloading(received: 10, expected: 100))] {
            h.updater.debugIndicatorPhase = phase
            #expect(installs.count == 0)
        }
        #expect(h.updater.card != nil, "the click's download shows no progress")
        h.updater.debugIndicatorPhase = .ready(version: "5.0.0")
        #expect(await eventually { installs.count == 1 }, "staged build 500 waits for a second click")
        #expect(h.sparkle.cancels == 1, "build 500 was dropped too")
    }

    @Test func aClickWithNothingNewerInstallsAtOnce() async throws {
        let (h, installs) = Self.make(newer: false)
        h.updater.installClicked()
        #expect(await eventually { installs.count == 1 })
        #expect(h.sparkle.cancels == 0)
        #expect(h.feed.fetches == 1, "the click read the feed \(h.feed.fetches) times")
    }

    /// A feed that does not answer never blocks the click past its deadline.
    @Test func aSlowFeedDoesNotHoldTheClick() async throws {
        let (h, installs) = Self.make(newer: true, held: true)
        h.updater.installClicked()
        for _ in 0..<40 where installs.count == 0 {
            try await Task.sleep(for: .milliseconds(20))
            h.clock.advance(by: .seconds(1))
        }
        #expect(installs.count == 1, "the click waits on a feed that never answers")
        #expect(h.sparkle.cancels == 0)
        h.feed.release()
    }

    /// The feed answers at once with build 500 while the pulled list is read past the click's
    /// deadline: the feed's answer still decides, so stale build 300 never installs, and build 500
    /// does not wait on the pulled list.
    @Test func aFeedThatAnsweredDecidesWhileThePulledListIsSlow() async throws {
        let (h, installs) = Self.make(newer: true)
        let (gate, open) = AsyncStream<Void>.makeStream()
        h.updater.pulledWatch.fetch = { _ in
            for await _ in gate {}
            return nil
        }
        defer { open.finish() }
        h.updater.installClicked()
        #expect(await eventually { h.sparkle.cancels == 1 }, "newer build 500 waited on the slow pulled list")
        for _ in 0..<5 {
            h.clock.advance(by: .seconds(1))
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(installs.count == 0, "the click's deadline installed stale build 300 though the feed had answered with 500")
        #expect(h.sparkle.cancels == 1 && h.sparkle.backgroundChecks == 1, "nothing looked for build 500")
        #expect(h.updater.newestFetch == .click)
    }

    /// Leo 2026-10-29: build 4091813159501 was staged at 18:16Z, 4092299464301 was on the feed at
    /// 18:19Z, and Restart to Update installed the stale one. The nightly asks before it downloads
    /// (`updates.downloadAutomatically` off by default), and the click's read of the feed only ran
    /// when found updates downloaded by themselves. Now the click is the yes to the newest build's
    /// download too: the staged build gives way, the card says "Getting the Newest Build…", the
    /// newest build downloads with no second click, and it installs once staged.
    @Test func withDownloadsAskingOneClickStillInstallsTheNewestBuild() async throws {
        let (h, installs) = Self.make(newer: true, downloadsAsk: true)
        h.updater.installClicked()
        #expect(await eventually { h.sparkle.cancels == 1 }, "the click kept stale staged build 300 though 500 is out")
        #expect(h.sparkle.backgroundChecks == 1, "nothing looked for build 500")
        #expect(installs.count == 0, "the click installed stale build 300")

        // Sparkle drops 300 and finds 500, which waits for a download (downloads ask).
        h.sparkle.staged = nil
        h.updater.debugIndicatorPhase = .hidden
        #expect(h.updater.card == .gettingNewest(nil, pulled: false), "nothing says the newest build is coming")
        h.updater.debugIndicatorPhase = .checking
        #expect(h.updater.card == .gettingNewest(nil, pulled: false))
        h.updater.debugIndicatorPhase = .available(version: "5.0.0")
        #expect(installs.downloads == 1, "build 500 waits for another click to download")
        let transfer = UpdateTransfer(stage: .downloading, fraction: 0.5)
        h.updater.debugIndicatorPhase = .downloading(transfer)
        #expect(h.updater.card == .gettingNewest(transfer, pulled: false))
        let shown = try #require(h.updater.cardPresentation)
        #expect(shown.title == UpdaterStrings.gettingNewest && shown.actions.isEmpty && shown.showsProgress)
        #expect(installs.count == 0)

        h.sparkle.staged = "500"
        h.updater.debugIndicatorPhase = .ready(version: "5.0.0")
        #expect(await eventually { installs.count == 1 }, "staged build 500 waits for a second click")
        #expect(h.sparkle.cancels == 1, "build 500 was dropped too")
        #expect(h.updater.newestFetch == nil)
    }

    /// A staged build that was pulled is never installed by the click, even when the feed has
    /// nothing newer than it (the feed serves an older good build): it is dropped, and the newest
    /// good build is fetched instead.
    @Test func aClickNeverInstallsAPulledStagedBuild() async throws {
        let (h, installs) = Self.make(newer: false, pulled: ["300"])
        h.updater.installClicked()
        #expect(await eventually { h.sparkle.cancels == 1 }, "the click installed pulled build 300")
        #expect(h.sparkle.backgroundChecks == 1)
        #expect(installs.count == 0)
        #expect(h.updater.installAfterSwap)
        #expect(h.updater.newestFetch == .click)

        // A cached appcast serves pulled build 300 again, and the carried click's read of the
        // pulled list fails: the click still drops it, installs nothing, and fetches nothing more.
        h.updater.pulledWatch.fetch = { _ in nil }
        h.sparkle.staged = nil
        h.updater.debugIndicatorPhase = .hidden
        h.updater.debugIndicatorPhase = .checking
        h.updater.debugIndicatorPhase = .downloading(.starting)
        h.sparkle.staged = "300"
        h.updater.debugIndicatorPhase = .ready(version: "3.0.0")
        #expect(await eventually { h.sparkle.cancels == 2 }, "the carried click kept pulled build 300 staged again")
        try await Task.sleep(for: .milliseconds(100))
        #expect(installs.count == 0, "the carried click installed pulled build 300")
        #expect(h.sparkle.backgroundChecks == 1, "pulled build 300 was fetched again")
    }

    /// With no installer this app can cancel, a pulled staged build is still never installed: the
    /// update sheet opens instead.
    @Test func aPulledStagedBuildThatCannotBeCancelledIsNotInstalled() async throws {
        let (h, installs) = Self.make(newer: false, pulled: ["300"])
        var sheets = 0
        h.updater.presentUpdateUI = { sheets += 1 }
        h.updater.cancelStaged = { false }
        h.updater.installClicked()
        #expect(await eventually { sheets == 1 }, "the click ended in silence")
        #expect(installs.count == 0, "the click installed pulled build 300")
    }

    /// The staged installer is not this app's to cancel (the click installs at once, with no read
    /// of the feed), and the staged build is known pulled: it is still never installed, and the
    /// update sheet opens instead.
    @Test func aKnownPulledStagedBuildIsNotInstalledWhenTheClickCannotReplaceIt() async throws {
        let (h, installs) = Self.make(newer: false, cancellable: false, pulled: ["300"])
        var sheets = 0
        h.updater.presentUpdateUI = { sheets += 1 }
        h.updater.cancelStaged = { false }
        await h.updater.pulledWatch.refresh().value
        h.updater.installClicked()
        #expect(installs.count == 0, "the click installed known-pulled build 300")
        #expect(sheets == 1, "the click ended in silence")
    }
}

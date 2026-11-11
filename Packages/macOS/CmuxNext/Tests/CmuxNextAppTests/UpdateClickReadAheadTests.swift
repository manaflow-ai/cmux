@testable import CmuxNextUpdater
import Foundation
import Testing
import CmuxNextWakeupsTestSupport

/// Leo 2026-11-08: "it's just you click the button and that just simply restarts the app really
/// quickly". The install click used to read the feed and the pulled list after the click, before
/// the relaunch (up to the 3 s deadline, or the pulled list's 15 s). Now they are read ahead, as
/// the Update Ready card appears and when cmux becomes active, and a click within
/// ``StagedUpdateRefresh/clickReadFreshness`` of a whole read decides at once. An older read is
/// read again at the click, as before.
@MainActor @Suite(.serialized) struct UpdateClickReadAheadTests {
    typealias Base = UpdateStagedYieldsToNewerTests

    func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    /// The harness with build 300 staged and nothing newer on the feed; installs counted.
    static func make() -> (Base.Harness, () -> Int) {
        let (h, installs) = UpdateClickInstallsNewestTests.make(newer: false)
        return (h, { installs.count })
    }

    /// Sparkle stages the build: it reads the pulled list before the download (`prepareUpdate`),
    /// downloads, then shows Update Ready.
    static func stage(_ h: Base.Harness) async {
        await h.updater.pulledWatch.refresh().value
        h.updater.debugIndicatorPhase = .hidden
        h.updater.debugIndicatorPhase = .downloading(.starting)
        h.updater.debugIndicatorPhase = .ready(version: "3.0.0")
    }

    /// The build Sparkle just staged is the feed's newest: the card records that and reads
    /// nothing, and the click installs with no feed read at all.
    @Test func aBuildSparkleJustStagedInstallsWithNoReadAtTheClick() async throws {
        let (h, installs) = Self.make()
        await Self.stage(h)
        #expect(h.updater.lastFeedRead?.newest == "300")
        #expect(h.updater.stagedRefresh.hasFreshRead(h.updater), "the staged build's own reads did not count for the click")
        h.updater.installClicked()
        #expect(await eventually { installs() == 1 }, "the click did not install the staged build")
        #expect(h.feed.fetches == 0, "the click read the feed: \(h.feed.fetches) reads")
        #expect(h.sparkle.cancels == 0)
    }

    @Test func aStaleReadIsReadAgainAtTheClick() async throws {
        let (h, installs) = Self.make()
        await Self.stage(h)
        #expect(await eventually { h.updater.stagedRefresh.hasFreshRead(h.updater) })
        h.updater.lastFeedRead = FeedRead(newest: "300", at: h.updater.now().addingTimeInterval(-(StagedUpdateRefresh.clickReadFreshness + 1)),
                                          ring: h.updater.ring)
        #expect(!h.updater.stagedRefresh.hasFreshRead(h.updater))
        h.updater.installClicked()
        #expect(await eventually { installs() == 1 }, "the click did not install the staged build")
        #expect(h.feed.fetches == 1, "a read older than \(StagedUpdateRefresh.clickReadFreshness) s was trusted at the click")
    }

    /// A read for another ring never decides the click: the person picked a ring after it.
    @Test func aReadOfAnotherRingIsNotTrusted() async throws {
        let (h, _) = Self.make()
        await Self.stage(h)
        #expect(await eventually { h.updater.stagedRefresh.hasFreshRead(h.updater) })
        h.updater.lastFeedRead = FeedRead(newest: "300", at: h.updater.now(), ring: h.updater.ring == .dev ? .nightly : .dev)
        #expect(!h.updater.stagedRefresh.hasFreshRead(h.updater))
    }

    /// Activation reads ahead with a plain read, only when the read is stale, and a newer build it
    /// finds swaps in at the click with no read at the click.
    @Test func activationReadsAheadOnlyWhenTheReadIsStale() async throws {
        let (h, _) = Self.make()
        await Self.stage(h)
        #expect(await eventually { h.updater.stagedRefresh.hasFreshRead(h.updater) })
        h.updater.prefetchForInstallClick()
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.feed.fetches == 0, "a fresh read was read again on activation")
        h.updater.lastFeedRead = FeedRead(newest: "300", at: h.updater.now().addingTimeInterval(-(StagedUpdateRefresh.clickReadFreshness + 1)),
                                          ring: h.updater.ring)
        h.updater.prefetchForInstallClick()
        #expect(await eventually { h.feed.fetches == 1 }, "activation did not read a stale feed ahead")
        #expect(await eventually { h.updater.stagedRefresh.hasFreshRead(h.updater) })
    }

    /// The rule: the read ahead is a plain read. It never consumes, delays or re-arms the pending
    /// scheduled probe, never sets probe state, and never answers a ring pick or an install click,
    /// which each still read the feed and act on it.
    @Test func theReadAheadNeverTakesAPendingCheck() async throws {
        let h = Base.make(ring: "dev")
        let probeAt = ManualClock.Instant(offset: .seconds(Base.interval))
        try #require(await eventually { h.clock.sleeperDeadlines.contains(probeAt) }, "no probe was armed")
        // Halfway to the scheduled probe, a read ahead runs and finds Dev build 500.
        h.clock.advance(by: .seconds(Base.interval / 2))
        await h.updater.readFeedAhead().value
        #expect(h.feed.fetches == 1)
        #expect(h.updater.lastFeedRead?.newest == "500")
        #expect(h.updater.lastProbe == nil, "the read ahead set probe state")
        #expect(!h.updater.isProbing)
        #expect(h.updater.stagedRefresh.task == nil, "the read ahead became the staged probe")
        #expect(h.updater.stagedRefresh.timer.isScheduled, "the read ahead ended the pending probe")
        #expect(h.clock.sleeperDeadlines.contains(probeAt), "the read ahead moved the pending probe")
        #expect(h.sparkle.cancels == 0, "the read ahead swapped the staged build")
        #expect(h.sparkle.backgroundChecks == 0)
        // The scheduled probe still runs at its own deadline, reads the feed itself and swaps.
        h.clock.advance(by: .seconds(Base.interval / 2))
        #expect(await eventually { h.feed.fetches == 2 }, "the scheduled probe did not read the feed at its deadline")
        #expect(await eventually { h.sparkle.cancels == 1 })
        #expect(h.sparkle.backgroundChecks == 1)
    }

    /// A ring pick while a read ahead is in flight still reads the picked ring itself.
    @Test func aRingPickDuringAReadAheadReadsThePickedRing() async throws {
        let h = Base.make(ring: "nightly", held: true)
        let ahead = h.updater.readFeedAhead()
        #expect(await eventually { h.feed.fetches == 1 })
        h.updater.follow(ring: "dev")
        #expect(await eventually { h.feed.fetches == 2 }, "the ring pick joined the read ahead instead of reading Dev")
        h.feed.release(); h.feed.release()
        await ahead.value
        #expect(await eventually { h.sparkle.cancels == 1 }, "Dev was picked but the staged Nightly build kept its installer")
        #expect(h.sparkle.backgroundChecks == 1)
    }
}

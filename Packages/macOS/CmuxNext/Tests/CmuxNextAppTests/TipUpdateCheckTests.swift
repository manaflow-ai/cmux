@testable import CmuxNextUpdater
import Foundation
import Testing
import CmuxNextWakeupsTestSupport

/// The tip app tracks the tip (Leo 2026-10-24: "I can have a separate thing going on, a separate
/// app where, like, that is able to just track the latest tip"). Sparkle checks it once an hour at
/// most, while the tip feed gets a build every 5 to 15 minutes; so the tip app reads its feed every
/// 5 minutes (``TipUpdateCheck``) and starts this app's check when a newer build is out, and a
/// staged tip is probed at the same interval (``StagedUpdateRefresh``). No other app changes.
@MainActor @Suite(.serialized) struct TipUpdateCheckTests {
    typealias Base = UpdateStagedYieldsToNewerTests

    /// `DisableAutoUpdate`, switchable while the test runs.
    nonisolated final class Policy: @unchecked Sendable {
        private let lock = NSLock()
        private var disabled = false
        var disablesUpdates: Bool {
            get { lock.withLock { disabled } }
            set { lock.withLock { disabled = newValue } }
        }
    }

    /// The tip feed: build 500, untagged (every ring takes it), and its deltas.
    static var feed: String { """
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>cmux NEXT DEV tip</title>
    <item><title>tip</title><sparkle:version>500</sparkle:version><pubDate>\(Base.pubDate(minutesAgo: 2))</pubDate>\
    <sparkle:deltas><enclosure url="https://files.cmux.com/nightly-next/tip/d.delta" sparkle:version="500" sparkle:deltaFrom="300"/></sparkle:deltas></item>
    </channel></rss>
    """ }

    struct Harness {
        let updater: UpdaterService
        let clock: ManualClock
        let feed: Base.CountingFeed
        let sparkle: Base.FakeSparkle
        let policy: Policy
        /// Checks the tip check started.
        let checks: Counter
    }

    @MainActor final class Counter {
        var count = 0
        var downloads = true
    }

    nonisolated static let tip = UpdateBuildIdentity(bundleIdentifier: UpdateBuildIdentity.tipBundleIdentifier, shortVersion: "0.1.0", build: "100",
                                                     minimumSystemVersion: nil, infoFeedURL: "https://files.cmux.com/nightly-next/tip/appcast-arm64.xml",
                                                     hasPublicKey: true)
    nonisolated static let nightly = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.next.staged-yields", shortVersion: "0.1.0", build: "100",
                                                         minimumSystemVersion: nil, infoFeedURL: "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml",
                                                         hasPublicKey: true)
    static let stable = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.next.staged-yields", shortVersion: "0.1.0", build: "100",
                                            minimumSystemVersion: nil, infoFeedURL: TipAppTrackTests.stableFeed, hasPublicKey: true)

    /// A nightly-next feed with build 500 published `minutesAgo` ago, listing deltas or not.
    static func nightlyFeed(minutesAgo: Double, deltas: Bool) -> String { """
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>cmux NEXT</title>
    <item><title>nightly</title><sparkle:version>500</sparkle:version><pubDate>\(Base.pubDate(minutesAgo: minutesAgo))</pubDate>\
    \(deltas ? "<sparkle:deltas><enclosure url=\"https://files-next.cmux.com/d.delta\" sparkle:version=\"500\" sparkle:deltaFrom=\"300\"/></sparkle:deltas>" : "")</item>
    </channel></rss>
    """ }

    /// A started updater on build 100 with nothing found yet; the person's interval is an hour.
    static func make(_ identity: UpdateBuildIdentity = tip, checkAutomatically: Bool = true, downloadAutomatically: Bool = true,
                     held: Bool = false, xml: String = feed) -> Harness {
        let defaults = UserDefaults(suiteName: "TipUpdateCheckTests.\(UUID().uuidString)")!
        let clock = ManualClock()
        let feed = Base.CountingFeed(xml: xml, held: held)
        let sparkle = Base.FakeSparkle()
        sparkle.staged = nil
        let policy = Policy()
        let checks = Counter()
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { policy.disablesUpdates },
                                     prober: UpdateProber(fetcher: feed, architecture: .arm64), defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false, now: { Base.now }, clock: clock)
        updater.announcementsFetch = false
        updater.notesLoader = { _ in nil }
        updater.stagedBuild = { sparkle.staged }
        updater.cancelStaged = { sparkle.cancels += 1; return true }
        updater.stagedRefresh.replaceable = { true }
        updater.stagedRefresh.startCheck = { sparkle.backgroundChecks += 1 }
        updater.tipCheck.startCheck = { checks.count += 1 }
        updater.configure(checkAutomatically: checkAutomatically, checkInterval: 3600, downloadAutomatically: downloadAutomatically, ring: "nightly")
        updater.start()
        return Harness(updater: updater, clock: clock, feed: feed, sparkle: sparkle, policy: policy, checks: checks)
    }

    func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    /// One interval passes; with `fetches`, the read it starts (the feed's fetch number `fetches`) ends.
    func tick(_ h: Harness, fetches: Int? = nil, interval: TimeInterval = TipUpdateCheck.interval) async throws {
        try await h.clock.waitForSleeper()
        h.clock.advance(by: .seconds(interval))
        guard let fetches else { return try await Task.sleep(for: .milliseconds(100)) }
        try #require(await eventually { h.feed.fetches >= fetches }, "no read of the feed at the interval")
        await h.updater.tipCheck.task?.value
        try #require(await eventually { h.updater.tipCheck.task == nil })
    }

    @Test func theTipAppChecksItsFeedEveryFiveMinutes() async throws {
        let h = Self.make()
        #expect(h.updater.tipCheck.timer.isScheduled, "the tip app armed no fast check")
        #expect(h.feed.fetches == 0, "the feed was read before the first interval")
        try await tick(h, fetches: 1)
        #expect(h.checks.count == 1, "build 500 is out but no check started to download it")
        #expect(h.updater.tipCheck.timer.isScheduled, "the next read was not armed")
        // The same build is asked for once: a download that failed does not run every interval.
        try await tick(h, fetches: 2)
        #expect(h.checks.count == 1, "build 500 was checked for again")
    }

    @Test func aStableAppArmsNoFastCheck() async throws {
        let h = Self.make(Self.stable)
        #expect(!h.updater.tipCheck.timer.isScheduled, "a stable app armed the fast check")
        h.clock.advance(by: .seconds(TipUpdateCheck.nightlyInterval * 2))
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.feed.fetches == 0)
        #expect(h.checks.count == 0)
    }

    /// A NIGHTLY reads its feed every 15 minutes (not the tip app's 5) and asks for a newer build
    /// that lists its deltas.
    @Test func aNightlyChecksItsFeedEveryFifteenMinutes() async throws {
        let h = Self.make(Self.nightly, xml: Self.nightlyFeed(minutesAgo: 2, deltas: true))
        #expect(h.updater.tipCheck.timer.isScheduled, "a NIGHTLY armed no fast check")
        try await h.clock.waitForSleeper()
        h.clock.advance(by: .seconds(TipUpdateCheck.interval))
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.feed.fetches == 0, "a NIGHTLY read its feed at the tip interval")
        try await tick(h, fetches: 1, interval: TipUpdateCheck.nightlyInterval - TipUpdateCheck.interval)
        #expect(h.checks.count == 1, "build 500 is out with its deltas but no check started")
        try await tick(h, fetches: 2, interval: TipUpdateCheck.nightlyInterval)
        #expect(h.checks.count == 1, "build 500 was checked for again")
    }

    /// A newer nightly build is asked for at once, whether or not its deltas are listed yet: the
    /// full update is never held back for them.
    @Test(arguments: [(2.0, false), (2.0, true), (60.0, false)])
    func aNightlyAsksForANewerBuildAtOnce(minutesAgo: Double, deltas: Bool) async throws {
        let h = Self.make(Self.nightly, xml: Self.nightlyFeed(minutesAgo: minutesAgo, deltas: deltas))
        try await tick(h, fetches: 1, interval: TipUpdateCheck.nightlyInterval)
        #expect(h.checks.count == 1, "build 500 was held back")
        #expect(h.updater.tipCheck.asked == "500")
    }

    @Test(arguments: [UpdateIndicatorPhase.checking, .downloading(.starting), .ready(version: "5.0.0"), .installing])
    func noCheckWhileAnUpdateIsFoundStagedOrInstalling(phase: UpdateIndicatorPhase) async throws {
        let h = Self.make()
        h.sparkle.staged = "500"
        h.updater.debugIndicatorPhase = phase
        #expect(!h.updater.tipCheck.timer.isScheduled, "the fast check stayed armed in \(phase)")
        h.clock.advance(by: .seconds(TipUpdateCheck.interval * 2))
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.checks.count == 0, "a check started in \(phase)")
        // Back to nothing waiting: the next read is an interval away.
        h.sparkle.staged = nil
        h.updater.debugIndicatorPhase = .hidden
        #expect(h.updater.tipCheck.timer.isScheduled)
    }

    @Test func aDisabledUpdaterNeverChecks() async throws {
        let h = Self.make()
        h.policy.disablesUpdates = true
        try await tick(h)
        #expect(h.feed.fetches == 0, "the feed was read under DisableAutoUpdate")
        #expect(h.checks.count == 0)
        #expect(!h.updater.tipCheck.timer.isScheduled, "the disabled updater kept waking every interval")
        // The policy lifts (a managed policy reload re-applies the download policy): reads resume.
        h.policy.disablesUpdates = false
        h.updater.applyManagedPolicy(channel: nil, minimumVersion: nil)
        try await tick(h, fetches: 1)
        #expect(h.checks.count == 1)
    }

    /// Without the automatic-install opt-in (the default on every channel since Leo 2026-10-27:
    /// "ask before the download + install step") the fast check still reads the feed; its check
    /// ends on the update-found step, which asks, and nothing reads again until it is answered.
    @Test(arguments: [TipUpdateCheckTests.tip, TipUpdateCheckTests.nightly])
    func withoutTheOptInTheFastCheckStillFindsTheUpdateAndAsks(identity: UpdateBuildIdentity) async throws {
        let h = Self.make(identity, downloadAutomatically: false, xml: identity == Self.tip ? Self.feed : Self.nightlyFeed(minutesAgo: 2, deltas: false))
        #expect(h.updater.tipCheck.timer.isScheduled, "the fast check waited for the opt-in")
        try await tick(h, fetches: 1, interval: TipUpdateCheck.interval(for: identity) ?? 0)
        #expect(h.checks.count == 1, "build 500 is out but no check started")
        // The check found it: the update-found step asks; the fast check keeps reading for a newer one.
        h.updater.debugIndicatorPhase = .available(version: "5.0.0")
        #expect(h.updater.availableButton == UpdateAvailableButton(version: "5.0.0"), "the found update did not ask")
        #expect(h.updater.readyCard == nil, "the found update staged without an answer")
        #expect(h.updater.tipCheck.timer.isScheduled, "a found update waiting on its ask stopped the fast check")
    }

    /// A found update waiting on its ask (shown, or hidden by its Hide) never stops the app from
    /// finding a newer one: a newer build ends the waiting prompt and is checked for; the same
    /// build is left alone.
    @Test func aNewerBuildReplacesAFoundUpdateWaitingOnItsAsk() async throws {
        let h = Self.make(Self.nightly, downloadAutomatically: false, xml: Self.nightlyFeed(minutesAgo: 2, deltas: false))
        var waiting: String? = "500"
        var dismissed = 0
        h.updater.availableBuild = { waiting }
        h.updater.dismissAvailable = { dismissed += 1 }
        h.updater.debugIndicatorPhase = .available(version: "5.0.0")
        h.updater.closeUpdateCard(.hideVersion)
        try await tick(h, fetches: 1, interval: TipUpdateCheck.nightlyInterval)
        #expect(dismissed == 0 && h.checks.count == 0, "the build already offered was checked for again")
        waiting = "300"
        try await tick(h, fetches: 2, interval: TipUpdateCheck.nightlyInterval)
        #expect(dismissed == 1, "the stale found update's prompt stayed open")
        #expect(h.checks.count == 1, "newer build 500 was never checked for behind a hidden found update")
    }

    /// The person's own check found it and they hid its card: nothing shows, so the reads go on and
    /// a newer build replaces it. While the card shows, the fast check leaves it alone.
    @Test func aNewerBuildReplacesAFoundUpdateThePersonHid() async throws {
        let h = Self.make(Self.nightly, downloadAutomatically: false, xml: Self.nightlyFeed(minutesAgo: 2, deltas: false))
        var dismissed = 0
        h.updater.availableBuild = { "300" }
        h.updater.dismissAvailable = { dismissed += 1 }
        h.updater.send(.checkRequested)
        h.updater.debugIndicatorPhase = .checking
        h.updater.debugIndicatorPhase = .available(version: "3.0.0")
        #expect(h.updater.card == .available(version: "3.0.0"))
        #expect(!h.updater.tipCheck.timer.isScheduled, "the fast check ran under the person's own found card")
        h.updater.closeUpdateCard(.hideVersion)
        #expect(h.updater.tipCheck.timer.isScheduled, "a found update the person hid stopped the fast check")
        try await tick(h, fetches: 1, interval: TipUpdateCheck.nightlyInterval)
        #expect(dismissed == 1 && h.checks.count == 1, "newer build 500 was never checked for behind the hidden card")
    }

    /// Nothing reads the feed before the settings load: `updates.checkAutomatically` may be off.
    @Test func noFastCheckBeforeTheSettingsLoad() {
        let updater = UpdaterService(identity: Self.nightly, policy: ManagedUpdatePolicy { false },
                                     defaults: UserDefaults(suiteName: "TipUpdateCheckTests.\(UUID().uuidString)")!,
                                     enableSparkle: false, recordsUpdates: false, clock: ManualClock())
        updater.announcementsFetch = false
        updater.start()
        #expect(!updater.tipCheck.timer.isScheduled, "the fast check armed before the settings loaded")
        #expect(!updater.releasePushMayRun, "the release push may run before the settings loaded")
        updater.configure(checkAutomatically: false, checkInterval: 3600, downloadAutomatically: false)
        #expect(!updater.tipCheck.timer.isScheduled && !updater.releasePushMayRun, "automatic checks off armed a read")
        updater.stopReleasePush()
    }

    /// Off the organization's channel (`UpdateChannel`), nothing of this app's own feed is checked for fast.
    @Test func offTheManagedChannelTheFastCheckStops() async throws {
        let h = Self.make(Self.nightly)
        h.updater.applyManagedPolicy(channel: "stable", minimumVersion: nil)
        #expect(!h.updater.tipCheck.timer.isScheduled, "a NIGHTLY under a stable UpdateChannel kept its fast check")
        h.updater.applyManagedPolicy(channel: nil, minimumVersion: nil)
        #expect(h.updater.tipCheck.timer.isScheduled)
    }

    @Test func turningAutomaticChecksOffStopsTheTimer() async throws {
        let h = Self.make()
        h.updater.configure(checkAutomatically: false, checkInterval: 3600, downloadAutomatically: true)
        #expect(!h.updater.tipCheck.timer.isScheduled, "automatic checks are off but a read is still pending")
        h.clock.advance(by: .seconds(TipUpdateCheck.interval * 2))
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.feed.fetches == 0)
        h.updater.configure(checkAutomatically: true, checkInterval: 3600, downloadAutomatically: true)
        try await tick(h, fetches: 1)
        #expect(h.checks.count == 1)
    }

    /// The update sheet shows a failure's details: no check replaces them, not even one whose read
    /// began before it opened; its close arms the next read.
    @Test func noCheckWhileTheUpdateSheetIsOpen() async throws {
        let h = Self.make(held: true)
        var sheetOpen = false
        h.updater.isSheetPresented = { sheetOpen }
        try await h.clock.waitForSleeper()
        h.clock.advance(by: .seconds(TipUpdateCheck.interval))
        try #require(await eventually { h.feed.fetches == 1 })
        sheetOpen = true
        h.feed.release()
        await h.updater.tipCheck.task?.value
        #expect(h.checks.count == 0, "a check replaced the open sheet's details")
        #expect(!h.updater.tipCheck.timer.isScheduled, "the next read was armed while the sheet is open")
        sheetOpen = false
        h.updater.updateSheetClosed()
        #expect(h.updater.tipCheck.timer.isScheduled, "closing the sheet armed no read")
        h.feed.release()
        try await tick(h, fetches: 2)
        #expect(h.checks.count == 1)
    }

    @Test func automaticChecksOffArmsNothing() async throws {
        let h = Self.make(checkAutomatically: false)
        #expect(!h.updater.tipCheck.timer.isScheduled)
    }

    /// A rollback stops offering the build left behind: the fast check does not fetch it again.
    @Test func aRolledBackBuildIsNotCheckedFor() async throws {
        let h = Self.make()
        h.updater.defaults.set("500", forKey: UpdaterService.skipsBuildsThroughKey)
        try await tick(h, fetches: 1)
        #expect(h.checks.count == 0)
    }

    /// Staged: the tip app probes every 5 minutes, not every `updates.checkIntervalSeconds`, so a
    /// newer tip replaces the staged one.
    @Test func aStagedTipGivesWayToANewerTipWithinFiveMinutes() async throws {
        let h = Self.make()
        h.sparkle.staged = "300"
        h.updater.debugIndicatorPhase = .ready(version: "3.0.0")
        #expect(h.updater.stagedRefresh.timer.isScheduled)
        try await h.clock.waitForSleeper()
        h.clock.advance(by: .seconds(TipUpdateCheck.interval))
        try #require(await eventually { h.sparkle.cancels == 1 }, "the staged tip waited for the hourly interval")
        #expect(h.sparkle.backgroundChecks == 1)
        #expect(h.checks.count == 0, "the idle check ran while an update waits")
    }

    /// A staged tip nothing can replace (deferred downloads, a disabled updater) keeps the person's
    /// interval instead of waking every 5 minutes for nothing; it probes fast again once it can.
    @Test func aStagedTipNothingCanReplaceKeepsThePersonsInterval() async throws {
        let h = Self.make()
        h.sparkle.staged = "300"
        h.updater.stagedRefresh.replaceable = { h.checks.downloads }
        h.checks.downloads = false
        h.updater.debugIndicatorPhase = .ready(version: "3.0.0")
        #expect(h.updater.stagedRefresh.timer.isScheduled)
        #expect(!h.updater.stagedRefresh.armedFast, "a staged tip nothing can replace probes every 5 minutes")
        h.checks.downloads = true
        h.updater.applyDownloadPolicy()
        #expect(h.updater.stagedRefresh.armedFast, "downloads are automatic again but the staged tip waits an hour")
        h.policy.disablesUpdates = true
        h.updater.applyManagedPolicy(channel: nil, minimumVersion: nil)
        #expect(!h.updater.stagedRefresh.armedFast, "a disabled updater probes every 5 minutes")
        #expect(h.updater.stagedRefresh.timer.isScheduled)
    }

    /// A NIGHTLY's staged update keeps the person's interval.
    @Test func aStagedNightlyKeepsThePersonsInterval() async throws {
        let h = Self.make(Self.nightly)
        h.sparkle.staged = "300"
        h.updater.debugIndicatorPhase = .ready(version: "3.0.0")
        // Other timers sleep on this clock too: `waitForSleeper` returned on one of those while the
        // staged probe's task had not read the clock yet, so the advance below pushed its hour to
        // 3900 s and the probe never ran (runs 41243133170, 41282022128, 41358792657). Wait for the
        // probe's own deadline, an hour from now.
        let probeAt = h.clock.now.advanced(by: .seconds(3600))
        try #require(await eventually { h.clock.sleeperDeadlines.contains(probeAt) }, "the staged probe never slept for the person's hour")
        h.clock.advance(by: .seconds(TipUpdateCheck.interval))
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.feed.fetches == 0, "a NIGHTLY probed its staged update at the tip interval")
        h.clock.advance(by: .seconds(3600 - TipUpdateCheck.interval))
        #expect(await eventually { h.feed.fetches == 1 }, "the NIGHTLY's hourly probe never ran")
    }
}

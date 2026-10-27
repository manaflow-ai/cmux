@testable import CmuxNextUpdater
import Foundation
import Testing
import CmuxNextWakeupsTestSupport

/// A staged update gives way to a newer build of the followed ring (Leo 2026-10-22: "how are the
/// dev build hot swaps? like the update ready i want the latest dev builds to be able to show
/// up"). Sparkle never reads the feed while an update waits, so without this a Dev build
/// published after the staged one waited for a restart. While an update waits, the feed is
/// probed once per check interval (and when the person checks or picks a ring); a strictly newer
/// item on the ring cancels the staged installer and starts Sparkle's background check, which
/// downloads and stages the newer build for the card.
@MainActor @Suite(.serialized) struct UpdateStagedYieldsToNewerTests {
    /// A feed whose fetches the test counts; with `held`, each fetch waits for ``release()``.
    final class CountingFeed: AppcastFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var released = 0
        let xml: String
        let held: Bool
        init(xml: String, held: Bool = false) {
            self.xml = xml
            self.held = held
        }
        var fetches: Int { lock.withLock { count } }
        /// Lets one held fetch (the oldest, or the next one to start) return.
        func release() {
            let next: CheckedContinuation<Void, Never>? = lock.withLock {
                guard !waiting.isEmpty else { released += 1; return nil }
                return waiting.removeFirst()
            }
            next?.resume()
        }
        func fetch(_ url: URL) async throws -> Data {
            lock.withLock { count += 1 }
            if held {
                await withCheckedContinuation { continuation in
                    let go: Bool = lock.withLock {
                        if released > 0 { released -= 1; return true }
                        waiting.append(continuation)
                        return false
                    }
                    if go { continuation.resume() }
                }
            }
            return Data(xml.utf8)
        }
    }

    /// What the stubbed Sparkle seams saw.
    @MainActor final class FakeSparkle {
        var staged: String? = "300"
        var cancels = 0
        var backgroundChecks = 0  // checks started to stage the newer build
    }

    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let interval: TimeInterval = 3600

    static func pubDate(minutesAgo: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: now.addingTimeInterval(-minutesAgo * 60))
    }

    /// Nightly 300 (the staged build) and, when given, a Dev build 500 published `devMinutesAgo`
    /// ago, listing deltas or not.
    static func feed(devMinutesAgo: Double? = 600, devDeltas: Bool = false) -> String {
        let deltas = devDeltas
            ? #"<sparkle:deltas><enclosure url="https://example.invalid/d.delta" sparkle:version="500" sparkle:deltaFrom="300"/></sparkle:deltas>"#
            : ""
        let dev = devMinutesAgo.map {
            "<item><title>dev</title><sparkle:version>500</sparkle:version><pubDate>\(pubDate(minutesAgo: $0))</pubDate>\(deltas)<sparkle:channel>cmux-next-dev</sparkle:channel></item>"
        } ?? ""
        return """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>cmux NEXT</title>
        <item><title>nightly</title><sparkle:version>300</sparkle:version><pubDate>\(pubDate(minutesAgo: 900))</pubDate><sparkle:channel>cmux-next</sparkle:channel></item>
        \(dev)
        </channel></rss>
        """
    }

    struct Harness {
        let updater: UpdaterService
        let clock: ManualClock
        let feed: CountingFeed
        let sparkle: FakeSparkle
    }

    /// A NIGHTLY on build 100 following `ring`, with build 300 staged ("Update Ready").
    static func make(ring: String, feed xml: String = feed(), held: Bool = false, replaceable: Bool = true,
                     checkAutomatically: Bool = true) -> Harness {
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.next.staged-yields", shortVersion: "1.0.0", build: "100",
                                           minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml", hasPublicKey: true)
        let defaults = UserDefaults(suiteName: "UpdateStagedYieldsToNewerTests.\(UUID().uuidString)")!
        let clock = ManualClock()
        let feed = CountingFeed(xml: xml, held: held)
        let sparkle = FakeSparkle()
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false },
                                     prober: UpdateProber(fetcher: feed, architecture: .arm64), defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false, now: { now }, clock: clock)
        updater.announcementsFetch = false
        updater.notesLoader = { _ in nil }
        updater.stagedBuild = { sparkle.staged }
        updater.cancelStaged = { sparkle.cancels += 1; return true }
        updater.stagedRefresh.replaceable = { replaceable }
        updater.stagedRefresh.startCheck = { sparkle.backgroundChecks += 1 }
        updater.configure(checkAutomatically: checkAutomatically, checkInterval: interval, downloadAutomatically: true, ring: ring)
        updater.start()
        updater.debugIndicatorPhase = .ready(version: "3.0.0")
        return Harness(updater: updater, clock: clock, feed: feed, sparkle: sparkle)
    }

    /// Waits until `condition` holds or `timeout` passes.
    func eventually(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    /// The probe the scheduled check started has finished.
    func settle(_ h: Harness, fetches: Int) async throws {
        try #require(await eventually { h.feed.fetches >= fetches }, "no probe read the feed")
        await h.updater.stagedRefresh.task?.value
        try #require(await eventually { h.updater.stagedRefresh.task == nil })
    }

    @Test func aNewerDevBuildReplacesTheStagedOneAtTheNextScheduledCheck() async throws {
        let h = Self.make(ring: "dev")
        #expect(h.feed.fetches == 0, "the feed was read before the scheduled check")
        try await h.clock.waitForSleeper()
        h.clock.advance(by: .seconds(Self.interval))
        try await settle(h, fetches: 1)
        #expect(h.sparkle.cancels == 1, "the staged build 300 kept its installer though Dev build 500 is out")
        #expect(h.sparkle.backgroundChecks == 1, "nothing asked Sparkle to download the newer build")
    }

    /// One probe per interval, and none while the staged build is still the newest one.
    @Test func theNewestStagedBuildIsKeptAndProbedOncePerInterval() async throws {
        let h = Self.make(ring: "nightly")
        try await h.clock.waitForSleeper()
        h.clock.advance(by: .seconds(Self.interval))
        try await settle(h, fetches: 1)
        #expect(h.sparkle.cancels == 0, "the newest staged build was dropped")
        #expect(h.sparkle.backgroundChecks == 0)
        try await h.clock.waitForSleeper()
        h.clock.advance(by: .seconds(Self.interval / 2))
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.feed.fetches == 1, "the feed was read again before an interval passed")
        h.clock.advance(by: .seconds(Self.interval / 2))
        try await settle(h, fetches: 2)
        #expect(h.sparkle.cancels == 0)
    }

    /// Switching Nightly to Dev while a Nightly build waits looks at Dev at once.
    @Test func pickingTheDevRingReplacesAStagedNightlyAtOnce() async throws {
        let h = Self.make(ring: "nightly")
        h.updater.follow(ring: "dev")
        try await settle(h, fetches: 1)
        #expect(h.sparkle.cancels == 1, "Dev was picked but the staged Nightly build kept its installer")
        #expect(h.sparkle.backgroundChecks == 1)
    }

    /// The person's own check while an update waits looks for a newer one too.
    @Test func aCheckWhileAnUpdateWaitsFindsTheNewerBuild() async throws {
        let h = Self.make(ring: "dev")
        h.updater.checkForUpdates()
        try await settle(h, fetches: 1)
        #expect(h.sparkle.cancels == 1)
        #expect(h.sparkle.backgroundChecks == 1)
    }

    @Test func anInstallInProgressIsNeverReplaced() async throws {
        let h = Self.make(ring: "dev")
        h.updater.debugIndicatorPhase = .installing
        h.clock.advance(by: .seconds(Self.interval * 2))
        h.updater.checkForUpdates()
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.feed.fetches == 0, "the feed was probed while the update installs")
        #expect(h.sparkle.cancels == 0, "an install in progress was cancelled")
    }

    /// Sparkle's own silent install (no held installer) or deferred downloads: nothing to swap,
    /// so the feed is not read; the timer keeps its interval.
    @Test func aStagedUpdateThisAppCannotReplaceIsLeftAlone() async throws {
        let h = Self.make(ring: "dev", replaceable: false)
        try await h.clock.waitForSleeper()
        h.clock.advance(by: .seconds(Self.interval))
        try await h.clock.waitForSleeper()
        #expect(h.feed.fetches == 0)
        #expect(h.sparkle.cancels == 0)
    }

    /// A scheduled swap never waits for the deltas nightly-next lists minutes after a build's full
    /// archive: a newer build replaces the staged one at once, deltas listed or not.
    @Test func aFreshDevBuildWithNoDeltasSwapsAtOnce() async throws {
        let h = Self.make(ring: "dev", feed: Self.feed(devMinutesAgo: 10))
        try await h.clock.waitForSleeper()
        h.clock.advance(by: .seconds(Self.interval))
        try await settle(h, fetches: 1)
        #expect(h.sparkle.cancels == 1, "a newer build was held back for its deltas")
        #expect(h.sparkle.backgroundChecks == 1)
    }

    @Test func aFreshDevBuildThatListsDeltasSwapsAtOnce() async throws {
        let h = Self.make(ring: "dev", feed: Self.feed(devMinutesAgo: 10, devDeltas: true))
        try await h.clock.waitForSleeper()
        h.clock.advance(by: .seconds(Self.interval))
        try await settle(h, fetches: 1)
        #expect(h.sparkle.cancels == 1)
        #expect(h.sparkle.backgroundChecks == 1)
    }

    @Test func aCheckThePersonAskedForTakesAFreshBuildAtOnce() async throws {
        let h = Self.make(ring: "dev", feed: Self.feed(devMinutesAgo: 10))
        h.updater.checkForUpdates()
        try await settle(h, fetches: 1)
        #expect(h.sparkle.cancels == 1)
    }

    /// A probe of the old ring in flight when the person picks Dev is not taken as Dev's answer:
    /// Dev is read when it ends, and its newer build replaces the staged one.
    @Test func aRingPickedWhileAProbeRunsReadsTheNewRing() async throws {
        let h = Self.make(ring: "nightly", held: true)
        h.updater.checkForUpdates()
        try #require(await eventually { h.feed.fetches == 1 })
        h.updater.follow(ring: "dev")
        h.feed.release()
        try #require(await eventually { h.feed.fetches == 2 }, "the Dev ring was never read")
        h.feed.release()
        try #require(await eventually { h.sparkle.backgroundChecks == 1 }, "the newer Dev build was not staged")
        #expect(h.sparkle.cancels == 1)
    }

    /// The reverse: a Dev probe in flight when the person goes back to Nightly does not cancel the
    /// staged build for a Dev build Nightly does not offer.
    @Test func leavingDevWhileAProbeRunsKeepsTheStagedBuild() async throws {
        let h = Self.make(ring: "dev", held: true)
        h.updater.checkForUpdates()
        try #require(await eventually { h.feed.fetches == 1 })
        h.updater.follow(ring: "nightly")
        h.feed.release()
        try #require(await eventually { h.feed.fetches == 2 }, "the Nightly ring was never read")
        h.feed.release()
        try await settle(h, fetches: 2)
        #expect(h.sparkle.cancels == 0, "a Dev build replaced the staged one after Nightly was picked")
    }

    /// Away and back while a probe runs: the probe read the ring before the first pick, so the ring
    /// is read again when it ends instead of taking that older answer.
    @Test func aRingPickedAwayAndBackWhileAProbeRunsIsReadAgain() async throws {
        let h = Self.make(ring: "nightly", held: true)
        h.updater.checkForUpdates()
        try #require(await eventually { h.feed.fetches == 1 })
        h.updater.follow(ring: "dev")
        h.updater.follow(ring: "nightly")
        h.feed.release()
        try #require(await eventually { h.feed.fetches == 2 }, "the probe from before the picks answered for Nightly")
        h.feed.release()
        try await settle(h, fetches: 2)
        #expect(h.sparkle.cancels == 0)
    }

    /// A click on Install while a probe runs joins that probe (a583): the newer Dev build it finds
    /// replaces the staged one once, and the click carries over to it.
    @Test func anInstallClickedWhileAProbeRunsTakesTheNewerBuild() async throws {
        let h = Self.make(ring: "dev", held: true)
        h.updater.preflightOverride = { nil }
        h.updater.checkForUpdates()
        try #require(await eventually { h.feed.fetches == 1 })
        h.updater.installClicked()
        h.feed.release()
        try #require(await eventually { h.sparkle.cancels == 1 }, "the click installed the staged build though Dev build 500 is out")
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.sparkle.cancels == 1, "the probe and the click both cancelled")
        #expect(h.sparkle.backgroundChecks == 1)
        #expect(h.updater.installAfterSwap, "the click does not carry over to build 500")
    }

    /// After a click on Install no scheduled probe runs, and none is armed again; the click's own
    /// read of the feed is the only one.
    @Test func anInstallClickEndsTheScheduledProbes() async throws {
        let h = Self.make(ring: "dev", feed: Self.feed(devMinutesAgo: nil))
        h.updater.preflightOverride = { nil }
        try await h.clock.waitForSleeper()
        h.updater.installClicked()
        try #require(await eventually { h.feed.fetches == 1 && !h.updater.stagedRefresh.clickWaits }, "the click did not read the feed")
        h.clock.advance(by: .seconds(Self.interval))
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.feed.fetches == 1, "a scheduled probe ran after the click on Install")
        #expect(!h.updater.stagedRefresh.timer.isScheduled, "a probe was armed again after the click on Install")
        #expect(h.sparkle.cancels == 0)
    }

    /// The person's check while an update waits ends with its probe when nothing newer is out: the
    /// next check nobody asked for (a scheduled one, or a later swap's) shows nothing.
    @Test func aCheckThatFindsNothingNewerLeavesNoAskBehind() async throws {
        let h = Self.make(ring: "nightly")
        h.updater.checkForUpdates()
        try await settle(h, fetches: 1)
        #expect(h.sparkle.cancels == 0)
        h.updater.debugIndicatorPhase = .checking
        #expect(h.updater.card == nil, "a check nobody asked for showed its progress")
    }

    /// The same when no probe can start (a staged update this app cannot replace): the card answers.
    @Test func aCheckWithNothingToReplaceLeavesNoAskBehind() async throws {
        let h = Self.make(ring: "dev", replaceable: false)
        h.updater.checkForUpdates()
        #expect(h.feed.fetches == 0)
        h.updater.debugIndicatorPhase = .checking
        #expect(h.updater.card == nil, "a check nobody asked for showed its progress")
    }

    /// Turning automatic checks off ends the pending probe; a new interval counts from the change.
    @Test func aScheduleChangeReplacesThePendingProbe() async throws {
        let h = Self.make(ring: "dev")
        #expect(h.updater.stagedRefresh.timer.isScheduled)
        h.updater.configure(checkAutomatically: false, checkInterval: Self.interval, downloadAutomatically: true)
        #expect(!h.updater.stagedRefresh.timer.isScheduled, "automatic checks are off but a probe is still pending")
        h.updater.configure(checkAutomatically: true, checkInterval: Self.interval * 2, downloadAutomatically: true)
        #expect(h.updater.stagedRefresh.timer.isScheduled, "turning checks back on armed no probe while an update waits")
        try await h.clock.waitForSleeper()
        h.clock.advance(by: .seconds(Self.interval))
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.feed.fetches == 0, "the old interval's deadline still fired")
        h.clock.advance(by: .seconds(Self.interval))
        try await settle(h, fetches: 1)
        #expect(h.sparkle.cancels == 1)
    }

    @Test func automaticChecksOffMeansNoScheduledProbe() async throws {
        let h = Self.make(ring: "dev", checkAutomatically: false)
        h.clock.advance(by: .seconds(Self.interval * 2))
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.feed.fetches == 0)
    }
}

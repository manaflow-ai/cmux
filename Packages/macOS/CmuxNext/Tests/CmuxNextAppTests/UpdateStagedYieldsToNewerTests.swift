@testable import CmuxNextUpdater
import Foundation
import Testing

/// A staged update gives way to a newer build of the followed ring (Leo 2026-10-22: "how are the
/// dev build hot swaps? like the update ready i want the latest dev builds to be able to show
/// up"). Sparkle never reads the feed while an update waits, so without this a Dev build
/// published after the staged one waited for a restart. While an update waits, the feed is
/// probed once per check interval (and when the person checks or picks a ring); a strictly newer
/// item on the ring cancels the staged installer and starts Sparkle's background check, which
/// downloads and stages the newer build for the card.
@MainActor @Suite(.serialized) struct UpdateStagedYieldsToNewerTests {
    /// A feed whose fetches the test counts.
    final class CountingFeed: AppcastFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let xml: String
        init(xml: String) { self.xml = xml }
        var fetches: Int { lock.withLock { count } }
        func fetch(_ url: URL) async throws -> Data {
            lock.withLock { count += 1 }
            return Data(xml.utf8)
        }
    }

    /// What the stubbed Sparkle seams saw.
    @MainActor final class FakeSparkle {
        var staged: String? = "300"
        var cancels = 0
        var backgroundChecks = 0
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

    /// Nightly 300 (the staged build) and, when given, a Dev build 500 published `devMinutesAgo` ago.
    static func feed(devMinutesAgo: Double? = 600) -> String {
        let dev = devMinutesAgo.map {
            "<item><title>dev</title><sparkle:version>500</sparkle:version><pubDate>\(pubDate(minutesAgo: $0))</pubDate><sparkle:channel>cmux-next-dev</sparkle:channel></item>"
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
    static func make(ring: String, feed xml: String = feed(), replaceable: Bool = true,
                     checkAutomatically: Bool = true) -> Harness {
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.next.staged-yields", shortVersion: "1.0.0", build: "100",
                                           minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml", hasPublicKey: true)
        let defaults = UserDefaults(suiteName: "UpdateStagedYieldsToNewerTests.\(UUID().uuidString)")!
        let clock = ManualClock()
        let feed = CountingFeed(xml: xml)
        let sparkle = FakeSparkle()
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false },
                                     prober: UpdateProber(fetcher: feed, architecture: .arm64), defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false, now: { now }, clock: clock)
        updater.announcementsFetch = false
        updater.notesLoader = { _ in nil }
        updater.stagedBuild = { sparkle.staged }
        updater.cancelStaged = { sparkle.cancels += 1; return true }
        updater.stagedRefresh.replaceable = { replaceable }
        updater.stagedRefresh.checkInBackground = { sparkle.backgroundChecks += 1 }
        updater.stagedRefresh.deltaWindow = 45 * 60
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

    /// A build that lists no deltas yet waits out the delta window (Sparkle would hold it once
    /// and the card would be empty until the next check); the next interval takes it.
    @Test func aFreshDevBuildWaitsForItsDeltas() async throws {
        let h = Self.make(ring: "dev", feed: Self.feed(devMinutesAgo: 10))
        try await h.clock.waitForSleeper()
        h.clock.advance(by: .seconds(Self.interval))
        try await settle(h, fetches: 1)
        #expect(h.sparkle.cancels == 0, "a build whose deltas may still come replaced the staged one")
    }

    @Test func automaticChecksOffMeansNoScheduledProbe() async throws {
        let h = Self.make(ring: "dev", checkAutomatically: false)
        h.clock.advance(by: .seconds(Self.interval * 2))
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.feed.fetches == 0)
    }
}

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
    }

    static func make(newer: Bool, held: Bool = false) -> (Base.Harness, Installs) {
        let h = Base.make(ring: "nightly", feed: feed(newer: newer), held: held)
        let installs = Installs()
        h.updater.preflightOverride = { nil }
        h.updater.installStaged = { installs.count += 1 }
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
}

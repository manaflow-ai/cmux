import AppKit
@testable import CmuxNextHangReports
import CmuxNextCompat
import CmuxNextInputCore
import CmuxNextInputCoreTestSupport
import CmuxNextMetrics
import CmuxNextTrace
import CmuxNextWakeups
import Foundation
import Testing

/// `stability.active_seconds` from ``MainThreadActivityFeed`` (p09-observability-109), the denominator of the
/// stability counts: the feed's own active-time ledger counts at an input once a minute has gathered, at
/// resign-active and at quit, each count once, with the fraction of a second kept for the next.
@MainActor
struct MainThreadActivityFeedStabilityTests {
    static let second = MainThreadReportLedgerTests.second

    /// The feed over a fresh metrics store, with the test's uptime clock, the app active from uptime 0.
    @MainActor final class Fixture {
        let inputs: MainThreadReportLedgerTests.Inputs
        let tap: FakeInputTap
        let center: NotificationCenter
        let store: MetricsStore
        let feed: MainThreadActivityFeed

        init(stability counted: Bool = true) {
            let runtime = TraceRuntime(role: .app)
            let profile = MetricsProfile(appVersion: "1.2.3", buildNumber: "45", channel: "nightly", osVersion: "26.1.0",
                                         hardwareClass: "Mac16,10", buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 28))
            let store = MetricsStore(role: .app, profile: profile, pid: 4242)
            _ = store.attach(to: runtime)
            let inputs = MainThreadReportLedgerTests.Inputs()
            let tap = FakeInputTap()
            let center = NotificationCenter()
            self.inputs = inputs
            self.tap = tap
            self.center = center
            self.store = store
            feed = MainThreadActivityFeed(ledger: inputs.ledger(), input: tap, events: AppEvents(center: center), isActive: true,
                                          stability: counted ? StabilityCounters(metrics: Metrics(runtime: runtime)) : nil,
                                          uptimeNanos: { inputs.uptime.withLock { $0 } })
        }

        /// A key at `nanos` of uptime (the clock moves there first).
        func key(at nanos: UInt64) {
            inputs.at(nanos)
            tap.deliver(InputEventRecord(type: .keyDown, timestamp: Double(nanos) / 1_000_000_000))
        }

        func resign(at nanos: UInt64) {
            inputs.at(nanos)
            center.post(name: NSApplication.didResignActiveNotification, object: nil)
        }

        func activate(at nanos: UInt64) {
            inputs.at(nanos)
            center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        }

        /// The samples of `stability.active_seconds`, then their sum (the seconds counted).
        var active: (UInt64, UInt64) {
            let histogram = store.delta().histograms.first { $0.name == HistogramID.stabilityActiveSeconds.name }
            return (histogram?.count ?? 0, histogram?.sum ?? 0)
        }
    }

    @Test func inputCountsOnlyOnceAMinuteHasGathered() {
        let fixture = Fixture()
        fixture.key(at: 10 * Self.second)
        fixture.key(at: 30 * Self.second)
        fixture.key(at: 59 * Self.second)
        #expect(fixture.active == (0, 0), "an input counted before 60 s gathered")
        fixture.key(at: 61 * Self.second)
        #expect(fixture.active == (1, 61))
        fixture.key(at: 90 * Self.second)
        #expect(fixture.active == (1, 61), "the next minute had not gathered")
        withExtendedLifetime(fixture.feed) {}
    }

    @Test func resignAndQuitEachCountWhatGatheredAndCarryTheFraction() {
        let fixture = Fixture()
        fixture.key(at: 61 * Self.second)
        #expect(fixture.active == (1, 61))
        fixture.resign(at: 70 * Self.second + Self.second / 2)       // 9.5 s more: 9 counted, the half kept
        #expect(fixture.active == (2, 70))
        fixture.activate(at: 100 * Self.second)
        fixture.key(at: 100 * Self.second + 6 * Self.second / 10)    // 0.6 s more: with the half, 1.1 s
        fixture.inputs.at(100 * Self.second + 7 * Self.second / 10)
        fixture.feed.applicationWillTerminate()
        #expect(fixture.active == (3, 71), "the quit lost the carried fraction or counted twice")
        fixture.feed.applicationWillTerminate()
        #expect(fixture.active == (3, 71), "a second quit counted the same seconds again")
    }

    @Test func aResignWithLessThanASecondCountsNothing() {
        let fixture = Fixture()
        fixture.resign(at: Self.second / 2)
        #expect(fixture.active == (0, 0))
        withExtendedLifetime(fixture.feed) {}
    }

    @Test func withNoStabilityTheFeedCountsNothing() {
        let fixture = Fixture(stability: false)
        fixture.key(at: 61 * Self.second)
        fixture.resign(at: 70 * Self.second)
        fixture.feed.applicationWillTerminate()
        #expect(fixture.active == (0, 0))
    }
}

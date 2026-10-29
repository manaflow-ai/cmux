import AppKit
@testable import CmuxNextHangReports
import CmuxNextCompat
import CmuxNextInputCore
import CmuxNextInputCoreTestSupport
import CmuxNextWakeups
import Foundation
import Testing

/// Active time by Chrome's rule (activation plus input, a 5-minute inactivity timeout) and the
/// main-thread histograms sent as deltas of the cumulative watchdog counts.
struct MainThreadReportLedgerTests {
    static let second: UInt64 = 1_000_000_000
    static let minute = 60 * second

    /// The uptime clock and the cumulative histograms a test moves by hand.
    final class Inputs: Sendable {
        let uptime = Mutex<UInt64>(0)
        let histograms = Mutex<MainThreadReportLedger.Histograms?>(nil)

        func at(_ nanos: UInt64) { uptime.withLock { $0 = nanos } }

        /// Adds `turns` main turns and `queued` queued inputs to the first fine bucket.
        func count(turns: UInt64, queued: UInt64 = 0) {
            histograms.withLock { read in
                var next = read ?? MainThreadReportLedger.Histograms(
                    edgesNanos: HangReportWireFormatTests.turnEdgesNanos,
                    turnCounts: [UInt64](repeating: 0, count: HangReportWireFormatTests.turnEdgesNanos.count + 1),
                    inputQueueingCounts: [UInt64](repeating: 0, count: HangReportWireFormatTests.turnEdgesNanos.count + 1))
                next.turnCounts[0] += turns
                next.inputQueueingCounts[0] += queued
                read = next
            }
        }

        func ledger() -> MainThreadReportLedger {
            MainThreadReportLedger(uptimeNanos: { self.uptime.withLock { $0 } }, histograms: { self.histograms.withLock { $0 } })
        }
    }

    // MARK: Active time (ActiveTimeLedger)

    @Test func activeTimeCountsOnlyBetweenActivationNotices() {
        let second = Self.second
        var ledger = ActiveTimeLedger()
        ledger.didResignActive(atNanos: 2 * second)              // not active: nothing to close
        ledger.didReceiveUserInput(atNanos: 3 * second)          // input while inactive counts nothing
        ledger.didBecomeActive(atNanos: 10 * second)
        ledger.didResignActive(atNanos: 15 * second + second / 2)
        #expect(!ledger.isActive)
        #expect(ledger.seconds(atNanos: 100 * second) == 5)    // inactive time adds nothing
        ledger.didBecomeActive(atNanos: 20 * second)
        ledger.didReceiveUserInput(atNanos: 22 * second)
        #expect(ledger.seconds(atNanos: 22 * second) == 7)     // the open span counts up to its last input
        #expect(ledger.seconds(atNanos: 19 * second) == 7)     // an older stamp adds nothing
        ledger.commit(seconds: 7, atNanos: 22 * second)          // the half second stays
        #expect(ledger.seconds(atNanos: 22 * second) == 0)
        ledger.didResignActive(atNanos: 23 * second + second / 2)
        #expect(ledger.seconds(atNanos: 30 * second) == 2)
        ledger.commit(seconds: .max, atNanos: 30 * second)
        #expect(ledger.seconds(atNanos: 30 * second) == 0)
    }

    @Test func anIdleFrontmostHourCountsNothingPastTheLastInput() {
        var ledger = ActiveTimeLedger()
        ledger.didBecomeActive(atNanos: 0)
        ledger.didReceiveUserInput(atNanos: 1 * Self.minute)
        // cmux stays frontmost for an hour with no input (an agent runs, the Mac kept awake).
        #expect(ledger.seconds(atNanos: 61 * Self.minute) == 60)
        ledger.didResignActive(atNanos: 61 * Self.minute)
        #expect(ledger.seconds(atNanos: 61 * Self.minute) == 60)
        // Input after the timeout starts a new span; the idle gap is never counted.
        ledger.didBecomeActive(atNanos: 70 * Self.minute)
        ledger.didReceiveUserInput(atNanos: 72 * Self.minute)
        ledger.didReceiveUserInput(atNanos: 90 * Self.minute)
        ledger.didReceiveUserInput(atNanos: 91 * Self.minute)
        #expect(ledger.seconds(atNanos: 91 * Self.minute) == 60 + 2 * 60 + 60)
    }

    @Test func inputWithinTheTimeoutKeepsASpanOpen() {
        var ledger = ActiveTimeLedger()
        ledger.didBecomeActive(atNanos: 0)
        for minute in stride(from: 4, through: 60, by: 4) {
            ledger.didReceiveUserInput(atNanos: UInt64(minute) * Self.minute)
        }
        #expect(ledger.seconds(atNanos: 60 * Self.minute) == 3_600)
        // A resign within the timeout of the last input counts up to the resign.
        ledger.didResignActive(atNanos: 63 * Self.minute)
        #expect(ledger.seconds(atNanos: 63 * Self.minute) == 63 * 60)
        #expect(ActiveTimeLedger.defaultInactivityTimeoutNanos == 5 * Self.minute)
    }

    // MARK: Deltas, commit and save

    @Test func twoBuildsFromTheSameCumulativeReadSendNoTurnTwice() {
        let inputs = Inputs()
        let ledger = inputs.ledger()
        inputs.count(turns: 500, queued: 7)
        ledger.restart()                                        // reports on: earlier turns are never sent
        inputs.count(turns: 120, queued: 3)
        let first = ledger.take()
        #expect(first.input.turnCounts[0] == 120)
        #expect(first.input.inputQueueingCounts[0] == 3)
        #expect(ledger.take() == first)                         // a read changes nothing
        ledger.commit(first)
        let second = ledger.take()
        #expect(second.input.turnCounts.allSatisfy { $0 == 0 })
        #expect(second.isEmpty)
        let built = HangReportFixtures.builder(wireSchema: .v3).build(context: HangReportFixtures.context(), watchdog: StallAggregate(),
                                                                       metricKit: [], mainThread: second.input)
        #expect(built.intervals.isEmpty)
        inputs.count(turns: 4)
        #expect(ledger.take().input.turnCounts[0] == 4)
    }

    @Test func aHistogramClearedSinceTheBaselineSendsItsWholeCount() {
        let inputs = Inputs()
        let ledger = inputs.ledger()
        inputs.count(turns: 50)
        ledger.restart()
        inputs.histograms.withLock { $0 = nil }
        inputs.count(turns: 9)                                  // `debug.hangs clear`, then 9 turns
        #expect(ledger.take().input.turnCounts[0] == 9)
    }

    @Test func aSaveAndLoadMidPeriodKeepsTheCountedTimeAndTurns() throws {
        let inputs = Inputs()
        let ledger = inputs.ledger()
        ledger.restart()
        ledger.didBecomeActive()
        inputs.at(90 * Self.second)
        ledger.didReceiveUserInput(atNanos: 90 * Self.second)
        inputs.count(turns: 30, queued: 2)
        let saved = try JSONDecoder().decode(MainThreadReportLedger.Saved.self, from: JSONEncoder().encode(ledger.saved()))
        #expect(saved.activeNanos == 90 * Self.second)
        #expect(!saved.isEmpty)

        // The next launch: a new uptime clock and empty watchdog histograms.
        let next = Inputs()
        let relaunched = next.ledger()
        relaunched.restart()
        relaunched.merge(saved)
        next.count(turns: 5)
        let taken = relaunched.take()
        #expect(taken.input.activeSeconds == 90)
        #expect(taken.input.turnCounts[0] == 35)
        #expect(taken.input.inputQueueingCounts[0] == 2)
        relaunched.commit(taken)
        #expect(relaunched.take().isEmpty)
    }

    // MARK: The feed

    @MainActor @Test func theFeedForwardsActivationAndInputAtMostOnceASecond() {
        let inputs = Inputs()
        let ledger = inputs.ledger()
        let tap = FakeInputTap()
        let center = NotificationCenter()
        // The app holds its one AppEvents for its lifetime; a subscription holds it weakly.
        let events = AppEvents(center: center)
        let feed = MainThreadActivityFeed(ledger: ledger, input: tap, events: events, isActive: false)
        #expect(!ledger.isActive)
        #expect(tap.classes == [.key, .button, .scroll])
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(ledger.isActive)
        tap.deliver(InputEventRecord(type: .keyDown, timestamp: 100))
        tap.deliver(InputEventRecord(type: .keyDown, timestamp: 100.5))   // within a second: not forwarded
        inputs.at(101 * Self.second)
        #expect(ledger.take().input.activeSeconds == 100)                 // the span runs to the input at 100 s
        tap.deliver(InputEventRecord(type: .scrollWheel, timestamp: 101))
        #expect(ledger.take().input.activeSeconds == 101)
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(!ledger.isActive)
        withExtendedLifetime((feed, events)) {}
    }
}

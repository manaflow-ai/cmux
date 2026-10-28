import CmuxNextCompat
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Task p01-process-084 of plans/cmux-next/chrome-parity/p01-process.md: cmux's watch on the Chromium
/// Host's UI thread (``ChromiumHostHangMonitor``) on a fake clock and a fake deadline. No deadline
/// with no input waiting or no page shown; "Chromium is busy" exactly ``ChromiumHostHangMonitor/busyAfter``
/// after the host last dispatched waiting input; Wait gives it that long again, an ack takes the banner
/// away, Reload Chromium ends the host. The remote shim's C callback reaches the monitor through its
/// registry token only while the monitor lives.
@MainActor @Suite struct ChromiumHostHangMonitorTests {
    /// The deadline: what is armed, and its fire, run by the test.
    @MainActor final class FakeDeadline: ChromiumHostBusyDeadline {
        private(set) var armed: Duration?
        private(set) var schedules = 0
        private(set) var cancels = 0
        private var action: (@MainActor @Sendable () -> Void)?

        func schedule(after delay: Duration, _ action: @escaping @MainActor @Sendable () -> Void) {
            armed = delay
            schedules += 1
            self.action = action
        }

        func cancel() {
            armed = nil
            cancels += 1
            action = nil
        }

        func fire() {
            let action = action
            (armed, self.action) = (nil, nil)
            action?()
        }
    }

    /// The fake clock.
    nonisolated final class FakeClock {
        var now = ContinuousClock.now
        func advance(_ duration: Duration) { now += duration }
    }

    private let deadline = FakeDeadline()
    private let clock = FakeClock()
    // Stand-ins for two page views, held for the test's life so their identifiers stay distinct.
    private let pageObject = NSObject()
    private let otherObject = NSObject()
    private var page: ObjectIdentifier { ObjectIdentifier(pageObject) }
    private var other: ObjectIdentifier { ObjectIdentifier(otherObject) }

    private func makeMonitor(shown: Bool = true) -> ChromiumHostHangMonitor {
        let monitor = ChromiumHostHangMonitor(deadline: deadline, now: { [clock] in clock.now })
        if shown { monitor.pageShown(page, true) }
        return monitor
    }

    @Test func noDeadlineWithoutWaitingInput() {
        let monitor = makeMonitor()
        #expect(deadline.schedules == 0, "a shown page with no input arms nothing")
        monitor.inputOutstanding()
        #expect(deadline.armed == .seconds(2))
        monitor.inputSettled()
        #expect(deadline.armed == nil && deadline.cancels == 1, "the host dispatched everything: no deadline")
        #expect(!monitor.isArmed)
        monitor.inputProgress()
        #expect(deadline.schedules == 1, "an ack with nothing waiting arms nothing")
    }

    @Test func busyTwoSecondsAfterTheFirstWaitingInput() {
        let monitor = makeMonitor()
        var changes: [Bool] = []
        monitor.onBusyChange = { changes.append($0) }
        monitor.inputOutstanding()
        #expect(deadline.armed == ChromiumHostHangMonitor.busyAfter)
        clock.advance(.milliseconds(1_999))
        #expect(!monitor.isBusy)
        clock.advance(.milliseconds(1))
        deadline.fire()
        #expect(monitor.isBusy && changes == [true])
        #expect(deadline.armed == nil, "busy: no deadline until an ack, Wait or Reload")
        monitor.inputSettled()
        #expect(!monitor.isBusy && changes == [true, false], "the host took the input: the banner goes")
    }

    /// An ack while later input waits moves the start of the wait; the deadline armed before it stays
    /// and, when it fires early, sleeps the rest (one schedule per ack at most, none per key).
    @Test func anAckRestartsTheWaitLazily() {
        let monitor = makeMonitor()
        monitor.inputOutstanding()
        clock.advance(.milliseconds(1_500))
        monitor.inputProgress()
        #expect(deadline.schedules == 1, "the armed deadline stays")
        clock.advance(.milliseconds(500))
        deadline.fire()
        #expect(!monitor.isBusy)
        #expect(deadline.armed == .milliseconds(1_500), "the rest of the 2 s since the ack")
        clock.advance(.milliseconds(1_500))
        deadline.fire()
        #expect(monitor.isBusy)
        monitor.inputProgress()
        #expect(!monitor.isBusy && deadline.armed == .seconds(2), "the host works again: no banner, 2 s from now")
    }

    @Test func noDeadlineWhileNoPageShows() {
        let monitor = makeMonitor(shown: false)
        monitor.inputOutstanding()
        #expect(deadline.schedules == 0, "hidden: no deadline")
        clock.advance(.seconds(5))
        monitor.pageShown(page, true)
        #expect(deadline.armed == .seconds(2), "shown: 2 s from the show, not from the input")
        monitor.pageShown(other, true)
        monitor.pageShown(page, false)
        #expect(deadline.armed == .seconds(2), "another page still shows")
        clock.advance(.seconds(2))
        deadline.fire()
        #expect(monitor.isBusy)
        monitor.pageShown(other, false)
        #expect(!monitor.isBusy && deadline.armed == nil, "every page hidden: no banner, no deadline")
    }

    @Test func waitGivesTheHostTwoSecondsMore() {
        let monitor = makeMonitor()
        monitor.inputOutstanding()
        clock.advance(.seconds(2))
        deadline.fire()
        #expect(monitor.isBusy)
        clock.advance(.seconds(3))
        monitor.keepWaiting()
        #expect(!monitor.isBusy && deadline.armed == .seconds(2))
        clock.advance(.seconds(2))
        deadline.fire()
        #expect(monitor.isBusy, "still no dispatch: busy again")
    }

    @Test func reloadEndsTheHostAndClearsTheBanner() {
        let monitor = makeMonitor()
        var reloads = 0
        #expect(!monitor.canReload)
        monitor.onReload = { reloads += 1 }
        #expect(monitor.canReload)
        monitor.inputOutstanding()
        clock.advance(.seconds(2))
        deadline.fire()
        monitor.reload()
        #expect(reloads == 1 && !monitor.isBusy && deadline.armed == nil)
    }

    /// The remote shim's events (`cmux_remote_host_watch_event`) through the C callback and the registry token.
    @Test func theHostWatchCallbackReachesTheLiveMonitorOnly() throws {
        var hangs: [ChromiumHostHang] = []
        let token: CallbackToken
        do {
            let monitor = makeMonitor()
            monitor.onHang = { hangs.append($0) }
            token = try monitor.token()
            #expect(try monitor.token() == token, "one token for the monitor's life")
            unsafe ChromiumHostHangMonitor.hostWatchCallback(token.context, ChromiumHostHangMonitor.inputOutstandingEvent, 0, 0)
            #expect(deadline.armed == .seconds(2))
            unsafe ChromiumHostHangMonitor.hostWatchCallback(token.context, ChromiumHostHangMonitor.hostHangEvent, 300_000_000, 2)
            #expect(hangs == [ChromiumHostHang(duration: .milliseconds(300), isOngoing: false, dumped: true)])
            unsafe ChromiumHostHangMonitor.hostWatchCallback(token.context, ChromiumHostHangMonitor.inputSettledEvent, 0, 0)
            #expect(deadline.armed == nil)
        }
        // The monitor and its registration are gone.
        let cancels = deadline.cancels
        unsafe ChromiumHostHangMonitor.hostWatchCallback(token.context, ChromiumHostHangMonitor.inputOutstandingEvent, 0, 0)
        #expect(deadline.schedules == 1 && deadline.cancels == cancels, "a frame after the monitor went finds nothing")
    }

    /// A turn that reaches the host's 10 s dump is reported at the dump and at its end; a hang report takes it once.
    /// The host says whether the end's hang was reported already (flag 4), so one its watcher missed still counts.
    @Test func aHangIsReportedOnce() {
        let short = ChromiumHostHang(durationNanos: 400_000_000, flags: 0)
        #expect(short == ChromiumHostHang(duration: .milliseconds(400), isOngoing: false, dumped: false) && short.isFirstReport)
        let atDump = ChromiumHostHang(durationNanos: 10_000_000_000, flags: 3)
        #expect(atDump.isOngoing && atDump.dumped && atDump.isFirstReport)
        let end = ChromiumHostHang(durationNanos: 12_000_000_000, flags: 6)
        #expect(!end.isOngoing && end.wasReported && !end.isFirstReport, "its end was reported at the dump")
        let missed = ChromiumHostHang(durationNanos: 12_000_000_000, flags: 0)
        #expect(!missed.wasReported && missed.isFirstReport, "no watcher report came: the end is the first report")
    }
}

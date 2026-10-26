import CmuxNextCompat
import CmuxNextCrashReporting
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Darwin
import Foundation
import Testing

/// The Sentry options: one hang watcher per process (Chrome's `HangWatcher`), so the SDK's
/// ANR thread is off (p14-energy-101).
@Suite struct CrashReporterOptionsTests {
    private static func reporter() -> CrashReporter {
        CrashReporter(policy: CrashReportingPolicy(bundleID: "com.cmuxterm.next.nightly", shortVersion: "1.0", build: "1",
                                                   isDebugBuild: false, telemetryOptIn: true, managedDisablesTelemetry: false,
                                                   processEnvironment: [:]))
    }

    @Test func theSDKsAppHangTrackerIsOff() {
        let options = Self.reporter().options()
        #expect(options.enableAppHangTracking == false)
    }

    @Test func theWatchdogsAppHangThresholdIsTheSDKsFormerTimeout() {
        #expect(CrashReporter.appHangThreshold == .seconds(8))
    }

    @Test func anAppHangEventHasTheSDKsShape() {
        let ongoing = AppHangEvent(duration: .seconds(8), ongoing: true, addresses: []).event()
        let hang = ongoing.exceptions?.first
        #expect(ongoing.exceptions?.count == 1)
        #expect(hang?.type == "App Hanging")
        #expect(hang?.value == "App hanging for at least 8000 ms.")
        #expect(hang?.mechanism?.type == "AppHang")
        #expect(ongoing.level == .error)
        #expect(ongoing.tags?["hang_source"] == "main_thread_watchdog")
        #expect(ongoing.tags?["hang_state"] == "ongoing")
        let ended = AppHangEvent(duration: .milliseconds(9_250), ongoing: false, addresses: []).event()
        #expect(ended.exceptions?.first?.value == "App hanging for 9250 ms.")
        #expect(ended.tags?["hang_state"] == "ended")
    }

    @Test func anAppHangEventKeepsTheMainThreadSampleAndItsImages() {
        // A real code address (malloc in libsystem), so dladdr finds its image.
        let address = UInt(bitPattern: dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc"))
        #expect(address != 0)
        let event = AppHangEvent(duration: .seconds(8), ongoing: true, addresses: [address],
                                 otherThreads: [(name: "worker", addresses: [address])]).event()
        #expect(event.exceptions?.first?.stacktrace?.frames.count == 1)
        #expect(event.exceptions?.first?.threadId == NSNumber(value: 0))
        #expect(event.threads?.count == 2)
        #expect(event.debugMeta?.isEmpty == false)
    }
}

/// Watchdog hang episodes to Sentry app hangs (``AppHangReporter``): at most one event per
/// episode, only for episodes of 8 s and up.
@Suite struct WatchdogReportingAppHangTests {
    private static let second: UInt64 = 1_000_000_000

    private struct Harness {
        let clock: ManualClock
        let uptime: HangUptime
        let sent: AppHangRecorder
        let deadline: DemandTimer
        let reporter: AppHangReporter

        init(enabled: Bool = true) {
            let clock = ManualClock()
            let uptime = HangUptime()
            let sent = AppHangRecorder()
            let deadline = DemandTimer(owner: "test.app-hang-deadline", clock: clock, ledger: WakeupLedger())
            self.clock = clock
            self.uptime = uptime
            self.sent = sent
            self.deadline = deadline
            reporter = AppHangReporter(threshold: .seconds(8), isEnabled: { enabled }, sink: { sent.add($0) },
                                       deadline: deadline, uptime: { uptime.now.load(ordering: .acquiring) })
        }

        /// The main thread stopped answering at `start` s and the watchdog reports it `after` s later.
        func hang(start: UInt64, after: UInt64) {
            uptime.now.store((start + after) * second, ordering: .releasing)
            reporter.noteHang(duration: .seconds(Int64(after)), addresses: [0x1000])
        }

        func stallEnded(start: UInt64, duration: Duration) {
            reporter.noteStall(startUptimeNanos: start * second, duration: duration)
        }
    }

    @Test func anEpisodeStillBlockedAtEightSecondsSendsExactlyOneEvent() async throws {
        let harness = Harness()
        harness.hang(start: 100, after: 2)
        try await harness.clock.waitForSleeper()
        harness.clock.advance(by: .seconds(6))
        let first = await harness.sent.next()
        #expect(first.ongoing)
        #expect(first.duration == .seconds(8))
        #expect(first.addresses == [0x1000])
        // The main thread answers at last: the episode already sent its one event.
        harness.stallEnded(start: 100, duration: .seconds(12))
        #expect(harness.sent.count == 1)
        #expect(!harness.deadline.isScheduled)
    }

    @Test func anEpisodeThatEndsPastEightSecondsBeforeTheDeadlineSendsOneExactEvent() async throws {
        let harness = Harness()
        harness.hang(start: 100, after: 2)
        try await harness.clock.waitForSleeper()
        harness.stallEnded(start: 100, duration: .milliseconds(8_400))
        #expect(harness.sent.count == 1)
        #expect(harness.sent.events.first?.ongoing == false)
        #expect(harness.sent.events.first?.duration == .milliseconds(8_400))
        #expect(!harness.deadline.isScheduled)
        harness.clock.advance(by: .seconds(6))
        #expect(harness.sent.count == 1)
    }

    @Test func anEpisodeShorterThanEightSecondsSendsNothing() async throws {
        let harness = Harness()
        harness.hang(start: 100, after: 2)
        try await harness.clock.waitForSleeper()
        harness.stallEnded(start: 100, duration: .seconds(3))
        #expect(!harness.deadline.isScheduled)
        harness.clock.advance(by: .seconds(6))
        #expect(harness.sent.count == 0)
    }

    @Test func aStallThatEndedBeforeItsHangReportOpensNoEpisode() {
        let harness = Harness()
        // The main thread answered after 2.5 s, before the watchdog's 2 s report reached the reporter.
        harness.stallEnded(start: 100, duration: .milliseconds(2_500))
        harness.uptime.now.store(103 * Self.second, ordering: .releasing)
        harness.reporter.noteHang(duration: .seconds(2), addresses: [])
        #expect(!harness.deadline.isScheduled)
        #expect(harness.sent.count == 0)
    }

    @Test func anEarlierStallDoesNotCloseALaterEpisode() async throws {
        let harness = Harness()
        harness.stallEnded(start: 90, duration: .milliseconds(300)) // ended at 90.3 s
        harness.hang(start: 100, after: 2)
        try await harness.clock.waitForSleeper()
        harness.stallEnded(start: 95, duration: .milliseconds(300)) // a late report of a stall before the hang
        #expect(harness.deadline.isScheduled)
        harness.clock.advance(by: .seconds(6))
        let event = await harness.sent.next()
        #expect(event.ongoing)
    }

    @Test func eachEpisodeSendsItsOwnEvent() async throws {
        let harness = Harness()
        harness.hang(start: 100, after: 2)
        harness.stallEnded(start: 100, duration: .seconds(9))
        harness.hang(start: 200, after: 2)
        harness.stallEnded(start: 200, duration: .seconds(10))
        #expect(harness.sent.events.map(\.duration) == [.seconds(9), .seconds(10)])
    }

    @Test func nothingIsArmedOrSentWhileReportingIsOff() {
        let harness = Harness(enabled: false)
        harness.hang(start: 100, after: 2)
        #expect(!harness.deadline.isScheduled)
        harness.stallEnded(start: 100, duration: .seconds(9))
        #expect(harness.sent.count == 0)
    }
}

/// The watchdog's uptime as the reporter reads it (a class: an `Atomic` cannot be captured).
private nonisolated final class HangUptime: Sendable {
    let now = Atomic<UInt64>(0)
}

/// Sent app hangs; ``next()`` returns the next one as it arrives.
private nonisolated final class AppHangRecorder: Sendable {
    private struct State {
        var events: [AppHangEvent] = []
        var read = 0
        var waiter: CheckedContinuation<AppHangEvent, Never>?
    }

    private let state = Mutex(State())

    var events: [AppHangEvent] { state.withLock { $0.events } }
    var count: Int { state.withLock { $0.events.count } }

    func add(_ event: AppHangEvent) {
        let waiter: CheckedContinuation<AppHangEvent, Never>? = state.withLock { state in
            state.events.append(event)
            guard let waiter = state.waiter else { return nil }
            state.waiter = nil
            state.read += 1
            return waiter
        }
        waiter?.resume(returning: event)
    }

    func next() async -> AppHangEvent {
        await withCheckedContinuation { (continuation: CheckedContinuation<AppHangEvent, Never>) in
            let ready: AppHangEvent? = state.withLock { state in
                guard state.read < state.events.count else {
                    state.waiter = continuation
                    return nil
                }
                state.read += 1
                return state.events[state.read - 1]
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

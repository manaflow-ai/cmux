@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextCrashReporting
import Darwin
import Foundation
import Testing

/// The app's Sentry options and app-hang events: one hang watcher per process (Chrome's `HangWatcher`), so the SDK's
/// ANR thread is off wherever the watchdog's sinks are set.
@Suite struct AppHangEventTests {
    /// The reporter as the app builds it: its hang tracking from the watchdog's sinks (`AppCrashReporting`).
    private static func reporter() -> CrashReporter {
        let sinks = WatchdogHangSinks(watchdog: MainThreadWatchdog(), keepsFatalHangRecord: false,
                                      markerFolder: FileManager.default.temporaryDirectory)
        return CrashReporter(policy: CrashReportingPolicy(bundleID: "com.cmuxterm.next.nightly", shortVersion: "1.0", build: "1",
                                                          isDebugBuild: false, telemetryOptIn: true, managedDisablesTelemetry: false,
                                                          processEnvironment: [:]),
                             hangTracking: sinks.hangTracking)
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

/// ``AppHangReporter``'s decision for each episode report: at most one event per episode, only
/// for episodes of 8 s and up.
@Suite struct AppHangReporterTests {
    private let sent = AppHangRecorder()
    private var reporter: AppHangReporter { AppHangReporter(threshold: .seconds(8)) { [sent] in sent.add($0) } }

    @Test func theFirstReportAtOrPastTheThresholdSendsOneOngoingEventWithItsStacks() {
        reporter.noteBlocked(duration: .seconds(2), previous: nil, addresses: [0x1])
        reporter.noteBlocked(duration: .seconds(4), previous: .seconds(2), addresses: [0x2])
        reporter.noteBlocked(duration: .milliseconds(8_100), previous: .seconds(4), addresses: [0x3])
        reporter.noteBlocked(duration: .milliseconds(16_200), previous: .milliseconds(8_100), addresses: [0x4])
        reporter.noteEnded(duration: .seconds(20), lastReport: .milliseconds(16_200), addresses: [0x4])
        #expect(sent.events.map(\.duration) == [.milliseconds(8_100)])
        #expect(sent.events.first?.ongoing == true)
        #expect(sent.events.first?.addresses == [0x3], "the stack sampled at the report, not at 2 s")
    }

    @Test func anEpisodeThatEndsPastTheThresholdBeforeAReportThereSendsItsExactLength() {
        reporter.noteBlocked(duration: .seconds(3), previous: nil, addresses: [0x1])
        reporter.noteBlocked(duration: .seconds(6), previous: .seconds(3), addresses: [0x2])
        reporter.noteEnded(duration: .milliseconds(9_250), lastReport: .seconds(6), addresses: [0x2])
        #expect(sent.events.count == 1)
        #expect(sent.events.first?.ongoing == false)
        #expect(sent.events.first?.duration == .milliseconds(9_250))
        #expect(sent.events.first?.addresses == [0x2])
    }

    @Test func aShorterEpisodeSendsNothing() {
        reporter.noteBlocked(duration: .seconds(2), previous: nil, addresses: [])
        reporter.noteBlocked(duration: .seconds(4), previous: .seconds(2), addresses: [])
        reporter.noteEnded(duration: .milliseconds(7_999), lastReport: .seconds(4), addresses: [])
        #expect(sent.events.isEmpty)
    }

    /// A sink set while an episode already ran (its first report to it is past the threshold).
    @Test func aFirstReportPastTheThresholdSendsTheOngoingEvent() {
        reporter.noteBlocked(duration: .seconds(16), previous: nil, addresses: [0x1])
        #expect(sent.events.map(\.ongoing) == [true])
    }
}

/// The watchdog's hang episodes through the app's sink (``AppHangReporter/episodeSink``, as
/// `WatchdogHangSinks.install(reporter:)` wires it), driven through the watch loop on the watchdog's own clock:
/// one 8 s episode gives one event, a 3 s one none.
@Suite struct WatchdogAppHangTests {
    @MainActor
    @Test(.timeLimit(.minutes(1))) func anEightSecondStallSendsOneEventAndAThreeSecondStallNone() {
        let harness = WatchdogHarness(hangThreshold: .seconds(2))
        defer { harness.watchdog.stop() }
        harness.advance(by: .seconds(2), thenWaitFor: 1) // 2 s: the hang began
        harness.advance(by: .seconds(2), thenWaitFor: 2) // 4 s checkpoint
        #expect(harness.sent.events.isEmpty)
        harness.advance(by: .seconds(4), thenWaitFor: 3) // 8 s checkpoint: the app hang
        #expect(harness.sent.events.map(\.ongoing) == [true])
        #expect(harness.sent.events.first?.duration == .seconds(8))
        harness.mainThreadAnswers(after: .milliseconds(500), thenWaitFor: 4)
        #expect(harness.sent.events.count == 1, "the end of an episode already reported sends nothing")

        harness.watchdog.heartbeat(.afterWaiting) // the next turn
        harness.advance(by: .seconds(2), thenWaitFor: 5)
        harness.mainThreadAnswers(after: .seconds(1), thenWaitFor: 6)
        #expect(harness.sent.events.count == 1, "a 3 s episode is a lag spike, not an app hang")
    }

    /// Checkpoints at 3 s and 6 s, then the 12 s one never comes: the end sends the exact length.
    @MainActor
    @Test(.timeLimit(.minutes(1))) func aStallThatEndsBetweenCheckpointsPastEightSecondsSendsItsExactLength() {
        let harness = WatchdogHarness(hangThreshold: .seconds(3))
        defer { harness.watchdog.stop() }
        harness.advance(by: .seconds(3), thenWaitFor: 1)
        harness.advance(by: .seconds(3), thenWaitFor: 2)
        harness.mainThreadAnswers(after: .seconds(3), thenWaitFor: 3)
        #expect(harness.sent.events.map(\.ongoing) == [false])
        #expect(harness.sent.events.first?.duration == .seconds(9))
    }
}

/// The watchdog's hang sinks, set before Sentry starts (`AppCrashReporting`), wire its app hangs: a hang in the rest
/// of launch reaches Sentry (the watchdog is the app's only app-hang source).
@Suite struct WatchdogAppHangSinkTests {
    @MainActor
    @Test func theHangSinksSetTheWatchdogsEpisodeSink() {
        let watchdog = MainThreadWatchdog(configuration: .init(sampleStacks: false, logStalls: false, hangAssertThreshold: nil))
        let unwired = watchdog.onHangEpisode == nil
        #expect(unwired)
        let sinks = WatchdogHangSinks(watchdog: watchdog, keepsFatalHangRecord: false, markerFolder: FileManager.default.temporaryDirectory)
        sinks.install(reporter: CrashReporter(policy: LaunchHangChild.policy(), hangTracking: sinks.hangTracking))
        let wired = watchdog.onHangEpisode != nil
        #expect(wired)
    }
}

/// A watchdog on a manual clock with its watch loop running and the app's episode sink to an
/// ``AppHangRecorder``; counts each episode report so a test can wait for the watchdog thread.
@MainActor
private final class WatchdogHarness {
    let watchdog: MainThreadWatchdog
    let sent: AppHangRecorder
    private let clock: WatchdogUptime
    private let reports: ReportCount

    init(hangThreshold: Duration) {
        let clock = WatchdogUptime()
        let sent = AppHangRecorder()
        let reports = ReportCount()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false,
                                                               hangThreshold: hangThreshold, hangAssertThreshold: nil),
                                          uptime: clock.read)
        (self.watchdog, self.sent, self.clock, self.reports) = (watchdog, sent, clock, reports)
        let appHangs = AppHangReporter(threshold: CrashReporter.appHangThreshold) { sent.add($0) }.episodeSink
        watchdog.onHangEpisode = { event in
            appHangs(event)
            reports.value.add(1, ordering: .releasing)
        }
        watchdog.heartbeat(.afterWaiting)
        watchdog.running.store(true, ordering: .releasing)
        let thread = Thread { watchdog.watch(sampler: nil) }
        thread.start()
    }

    /// Moves the watchdog's clock while the main thread stays blocked, then waits until the
    /// watchdog thread made `count` episode reports in all.
    func advance(by duration: Duration, thenWaitFor count: Int) {
        clock.advance(by: duration)
        waitForReports(count)
    }

    /// The main thread's turn ends `duration` later (it measures the stall's exact length).
    func mainThreadAnswers(after duration: Duration, thenWaitFor count: Int) {
        clock.advance(by: duration)
        watchdog.heartbeat(.beforeWaiting)
        waitForReports(count)
    }

    private func waitForReports(_ count: Int) {
        let deadline = ContinuousClock.now + .seconds(10)
        while reports.value.load(ordering: .acquiring) < count, ContinuousClock.now < deadline { usleep(2_000) }
        #expect(reports.value.load(ordering: .acquiring) == count)
    }
}

/// Sent app hangs (a class: `Mutex` cannot be captured).
private nonisolated final class AppHangRecorder: Sendable {
    private let sent = Mutex<[AppHangEvent]>([])
    var events: [AppHangEvent] { sent.withLock { $0 } }
    func add(_ event: AppHangEvent) { sent.withLock { $0.append(event) } }
}

/// Episode reports the watchdog thread made (a class: an `Atomic` cannot be captured).
private nonisolated final class ReportCount: Sendable {
    let value = Atomic<Int>(0)
}

/// The watchdog's `CLOCK_UPTIME_RAW` stand-in: moves only when the test moves it.
private nonisolated final class WatchdogUptime: Sendable {
    private let nanos = Atomic<UInt64>(1_000_000_000)
    var read: @Sendable () -> UInt64 { { [self] in nanos.load(ordering: .acquiring) } }
    func advance(by duration: Duration) {
        let (seconds, attoseconds) = duration.components
        nanos.add(UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds / 1_000_000_000), ordering: .releasing)
    }
}

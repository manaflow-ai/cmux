@testable import CmuxNextControl
@testable import CmuxNextControlDiagnostics
import CmuxNextCompat
import Testing

/// The main-turn sink (the startup trace's main-thread slices): a turn is wake to sleep, and only turns of
/// at least the minimum reach the sink. Heartbeats driven by hand on an injected clock.
@Suite struct MainThreadWatchdogMainTurnTests {
    @MainActor
    @Test func sendsTurnsAtLeastTheMinimumWithTheirWakeAndSleep() {
        let clock = ManualUptime()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false), uptime: clock.read)
        let turns = TurnLog()
        watchdog.setMainTurnSink(minimumNanos: 1_000_000) { start, end in turns.add(start, end) }
        clock.advance(by: .milliseconds(5))
        let wake = clock.read()
        watchdog.heartbeat(.afterWaiting)
        clock.advance(by: .microseconds(400))
        watchdog.heartbeat(.beforeTimers)
        clock.advance(by: .milliseconds(2))
        watchdog.heartbeat(.beforeWaiting)
        // A short turn is not sent.
        watchdog.heartbeat(.afterWaiting)
        clock.advance(by: .microseconds(900))
        watchdog.heartbeat(.beforeWaiting)
        let sent = turns.all
        #expect(sent.count == 1)
        #expect(sent.first?.0 == wake)
        #expect(sent.first?.1 == wake + 2_400_000)
    }

    /// `start()` runs inside a turn (applicationDidFinishLaunching) whose wake the watchdog never saw: that
    /// turn starts at `start()`, not at 0 (a slice from boot that zoomed the whole trace out to the uptime).
    @MainActor
    @Test func theTurnThatStartsTheWatchdogBeginsAtStartNotAtZero() {
        let clock = ManualUptime()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false),
                                          uptime: clock.read)
        let turns = TurnLog()
        watchdog.setMainTurnSink(minimumNanos: 1_000_000) { start, end in turns.add(start, end) }
        let started = clock.read()
        watchdog.start()
        defer { watchdog.stop() }
        clock.advance(by: .milliseconds(3))
        watchdog.heartbeat(.beforeWaiting)
        let sent = turns.all
        #expect(sent.count == 1)
        #expect(sent.first?.0 == started)
        #expect(sent.first?.1 == started + 3_000_000)
    }

    /// A sleep whose wake was never stamped (start 0) sends nothing.
    @MainActor
    @Test func aTurnWithNoSeenWakeIsNotSent() {
        let clock = ManualUptime()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false), uptime: clock.read)
        let turns = TurnLog()
        watchdog.setMainTurnSink(minimumNanos: 1_000_000) { start, end in turns.add(start, end) }
        watchdog.mainAsleep.store(false, ordering: .releasing)
        clock.advance(by: .milliseconds(3))
        watchdog.heartbeat(.beforeWaiting)
        #expect(turns.all.isEmpty)
    }

    @MainActor
    @Test func noSinkAndARemovedSinkSendNothing() {
        let clock = ManualUptime()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false), uptime: clock.read)
        #expect(watchdog.mainTurnMinimumNanos.load(ordering: .relaxed) == .max)
        let turns = TurnLog()
        watchdog.setMainTurnSink(minimumNanos: 0) { start, end in turns.add(start, end) }
        watchdog.setMainTurnSink(minimumNanos: 0, nil)
        #expect(watchdog.mainTurnMinimumNanos.load(ordering: .relaxed) == .max)
        watchdog.heartbeat(.afterWaiting)
        clock.advance(by: .milliseconds(20))
        watchdog.heartbeat(.beforeWaiting)
        #expect(turns.all.isEmpty)
    }
}

/// The turns a test's sink received, from any thread.
private final class TurnLog: Sendable {
    private let turns = Mutex<[(UInt64, UInt64)]>([])
    var all: [(UInt64, UInt64)] { turns.withLock { $0 } }
    func add(_ start: UInt64, _ end: UInt64) { turns.withLock { $0.append((start, end)) } }
}

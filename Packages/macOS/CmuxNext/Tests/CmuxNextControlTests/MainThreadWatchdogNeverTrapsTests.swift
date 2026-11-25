@testable import CmuxNextControl
import Foundation
import CmuxNextCompat
import Testing

/// https://github.com/manaflow-ai/cmux/issues/50992: a DEV build on a Mac at load 334 on 15 cores
/// ended with SIGTRAP in `checkHang`. Its main thread was blocked 11 s in a kernel call (an IOKit
/// registry read under a Chromium callback, no CPU), and the stall ended while the watchdog checked
/// it: the CPU reading went with the heartbeat, a nil the debug assertion read as "unreadable,
/// wall-clock time decides". The watchdog now never traps, an unknown CPU time is no busy hang,
/// and the main thread publishes the next heartbeat before its own stall bookkeeping.
@Suite(.serialized, .timeLimit(.minutes(1))) struct MainThreadWatchdogNeverTrapsTests {
    #if DEBUG
    /// The crash's shape on the live watch loop: a hang past the 10 s threshold whose main-thread
    /// CPU cannot be read (no watched thread here, as when the reading is gone with an ended beat).
    /// Before the fix this test process died in `assertionFailure`; now the hang is reported and
    /// the app lives on with no busy-hang fault.
    @Test func aBlockedHangPastTheAssertThresholdIsReportedAndNeverTraps() throws {
        let clock = ManualUptime()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false,
                                                               hangThreshold: .seconds(2), hangAssertThreshold: .seconds(10)),
                                          uptime: clock.read)
        let reported = DispatchSemaphore(value: 0), checkedAfterHang = DispatchSemaphore(value: 0)
        let hangs = CallCount()
        watchdog.onHang = { _ in
            hangs.value.add(1, ordering: .relaxed)
            reported.signal()
        }
        // The wait after `checkHang` returns: the busy-hang check of that pass has run.
        watchdog.beforeWaitForTesting.withLock { $0 = { _ in if hangs.value.load(ordering: .relaxed) > 0 { checkedAfterHang.signal() } } }
        watchdog.heartbeat(.afterWaiting)
        watchdog.running.store(true, ordering: .releasing)
        let thread = Thread { watchdog.watch(sampler: nil) }
        thread.start()
        defer { watchdog.stop() }
        clock.advance(by: .seconds(11))
        watchdog.alarm.wake()
        #expect(reported.wait(timeout: .now() + 20) == .success, "the hang was not reported")
        #expect(checkedAfterHang.wait(timeout: .now() + 20) == .success, "the watchdog did not finish its check")
        let busyHangFaults = watchdog.busyHangFaults.load(ordering: .relaxed), hangCount = hangs.value.load(ordering: .relaxed)
        #expect(busyHangFaults == 0, "an unknown CPU time was taken for a busy hang")
        #expect(hangCount == 1)
        watchdog.heartbeat(.beforeWaiting)
        #expect(watchdog.log.records().map(\.duration) == [.seconds(11)])
    }
    #endif

    /// The watchdog thread must see a stall as over while the main thread logs it: by the time
    /// ``MainThreadWatchdog/onStall`` runs (the end of the stall's bookkeeping), the next heartbeat
    /// is published, so the log's own work never counts as more of the same stall; and the loop
    /// still reads as awake, so a slow sink is watched as a turn of its own, not taken for sleep.
    @MainActor
    @Test func theNextHeartbeatIsPublishedBeforeTheStallIsLogged() {
        let clock = ManualUptime()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false,
                                                               hangAssertThreshold: nil), uptime: clock.read)
        watchdog.heartbeat(.afterWaiting)
        let stallBeat = watchdog.beatSequence.load(ordering: .acquiring)
        let seen = SeenBeats()
        watchdog.onStall = { [weak watchdog] _ in
            guard let watchdog else { return }
            seen.values.withLock { $0.append(watchdog.beatSequence.load(ordering: .acquiring)) }
            // Still awake: a slow sink here is a turn the watchdog watches, not time asleep.
            if watchdog.mainAsleep.load(ordering: .acquiring) { seen.asleepDuringLog.store(true, ordering: .relaxed) }
        }
        clock.advance(by: .seconds(3))
        watchdog.heartbeat(.beforeWaiting)
        #expect(seen.values.withLock { $0 } == [stallBeat &+ 1], "onStall ran before the stall's heartbeat moved on")
        // Read into locals: an `Atomic` is not copyable, so `#expect` cannot capture it in its expansion.
        let asleepDuringLog = seen.asleepDuringLog.load(ordering: .relaxed)
        let asleepAfter = watchdog.mainAsleep.load(ordering: .acquiring)
        #expect(!asleepDuringLog, "onStall ran after the loop was published asleep")
        #expect(asleepAfter, "the before-waiting heartbeat left the loop awake")
        // The ended hang's exact length is still there for its file.
        #expect(watchdog.closeEpisode(beat: stallBeat, lastElapsedNanos: 2_100_000_000) == 3_000_000_000)
    }
}

/// Heartbeat sequences `onStall` saw (a class: `Mutex` cannot be captured).
final class SeenBeats: Sendable {
    let values = Mutex<[UInt64]>([])
    let asleepDuringLog = Atomic(false)
}

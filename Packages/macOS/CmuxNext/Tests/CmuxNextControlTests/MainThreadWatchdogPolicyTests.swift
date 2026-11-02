@testable import CmuxNextControl
import Darwin
import Foundation
import Testing

struct MainThreadWatchdogPolicyTests {
    @Test func noActivateDiagnosticLaunchKeepsWatchdogEvidenceAlive() {
        #expect(MainThreadWatchdog.Configuration.hangAssertThreshold(debugBuild: true, noActivate: true) == nil)
    }

    @Test func interactiveDebugLaunchKeepsHangAssertion() {
        #expect(MainThreadWatchdog.Configuration.hangAssertThreshold(debugBuild: true, noActivate: false) == .seconds(10))
    }

    @Test func releaseLaunchNeverAsserts() {
        #expect(MainThreadWatchdog.Configuration.hangAssertThreshold(debugBuild: false, noActivate: false) == nil)
        #expect(MainThreadWatchdog.Configuration.hangAssertThreshold(debugBuild: false, noActivate: true) == nil)
    }

    /// A backgrounded (App Nap, throttled) app can leave the heartbeat stale
    /// for 10 s while the main thread idles in mach_msg or barely runs. That
    /// is still reported as a hang, but it must not fail the debug assertion:
    /// only a main thread that burned CPU through the stall is "busy".
    @Test func idleOrThrottledStallDoesNotFailHangAssertion() {
        let assertNanos: UInt64 = 10_000_000_000
        #expect(!MainThreadWatchdog.hangFailsAssertion(elapsedNanos: 11_000_000_000, mainThreadCPUNanos: 0, assertNanos: assertNanos))
        #expect(!MainThreadWatchdog.hangFailsAssertion(elapsedNanos: 11_000_000_000, mainThreadCPUNanos: 200_000_000, assertNanos: assertNanos))
    }

    @Test func busyStallPastThresholdFailsHangAssertion() {
        let assertNanos: UInt64 = 10_000_000_000
        #expect(MainThreadWatchdog.hangFailsAssertion(elapsedNanos: 10_500_000_000, mainThreadCPUNanos: 9_800_000_000, assertNanos: assertNanos))
        #expect(!MainThreadWatchdog.hangFailsAssertion(elapsedNanos: 9_000_000_000, mainThreadCPUNanos: 9_000_000_000, assertNanos: assertNanos))
        // CPU unreadable: keep the wall-clock assertion.
        #expect(MainThreadWatchdog.hangFailsAssertion(elapsedNanos: 10_500_000_000, mainThreadCPUNanos: nil, assertNanos: assertNanos))
    }

    /// The watchdog thread reads the watched thread's CPU time (thread_info
    /// on its port), and it moves when that thread works. The watched thread
    /// is a thread of its own, not the main thread: `watchCurrentThread()`
    /// takes whichever thread calls it, and spinning on the main actor held
    /// it for seconds on a loaded host (80 ms of CPU took 3.5-4.1 s of wall
    /// time), so main-actor tests running in parallel missed their deadlines
    /// (ActionRunCreatedTests' 2 s `action.run`, run 39882563236).
    @Test func mainThreadCPUIsReadableFromAnotherThreadAndMovesWithWork() async throws {
        let busy = BusyWatchdog(log: HangLog(capacity: 1))
        let (steps, step) = AsyncStream<Void>.makeStream()
        let spin = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
        let watched = Thread {
            busy.watchCurrentThread()
            step.yield()
            spin.wait()
            // Spin on this thread's own CPU clock (wall time is no bound on a
            // loaded host); the cap turns a starved thread into a failure, not a hang.
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let cap = ContinuousClock.now + .seconds(10)
            while clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- start < 80_000_000, ContinuousClock.now < cap {}
            step.yield()
            // Stays alive while the test reads its CPU time, then ends the stream.
            finish.wait()
            step.finish()
        }
        watched.start()
        var next = steps.makeAsyncIterator()
        await next.next()
        let before = busy.mainThreadCPUNanos()
        spin.signal()
        await next.next()
        let after = busy.mainThreadCPUNanos()
        // Join: the thread ends (and the stream with it) before the test does.
        finish.signal()
        while await next.next() != nil {}
        let readBefore = try #require(before), readAfter = try #require(after)
        #expect(readAfter >= readBefore + 50_000_000, "before \(readBefore) ns, after \(readAfter) ns")
    }
}

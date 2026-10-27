@testable import CmuxNextControl
@testable import CmuxNextControlDiagnostics
import Darwin
import Testing

struct MainThreadWatchdogPolicyTests {
    @Test func noActivateDiagnosticLaunchKeepsWatchdogEvidenceAlive() {
        #expect(MainThreadWatchdog.Configuration.hangAssertThreshold(debugBuild: true, isolatedLaunch: true) == nil)
    }

    @Test func interactiveDebugLaunchKeepsHangAssertion() {
        #expect(MainThreadWatchdog.Configuration.hangAssertThreshold(debugBuild: true, isolatedLaunch: false) == .seconds(10))
    }

    @Test func releaseLaunchNeverAsserts() {
        #expect(MainThreadWatchdog.Configuration.hangAssertThreshold(debugBuild: false, isolatedLaunch: false) == nil)
        #expect(MainThreadWatchdog.Configuration.hangAssertThreshold(debugBuild: false, isolatedLaunch: true) == nil)
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

    /// The watchdog thread reads the main thread's CPU time (thread_info on
    /// its port), and it moves when the main thread works.
    @MainActor
    @Test func mainThreadCPUIsReadableFromAnotherThreadAndMovesWithWork() async throws {
        let busy = BusyWatchdog(log: HangLog(capacity: 1))
        busy.watchCurrentThread()
        let before = try #require(await Task.detached { busy.mainThreadCPUNanos() }.value)
        // Spin on the main thread's own CPU clock (wall time is no bound on a
        // loaded host); the cap turns a starved thread into a failure, not a hang.
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let cap = ContinuousClock.now + .seconds(10)
        while clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- start < 80_000_000, ContinuousClock.now < cap {}
        let after = try #require(await Task.detached { busy.mainThreadCPUNanos() }.value)
        #expect(after >= before + 50_000_000, "before \(before) ns, after \(after) ns")
    }
}

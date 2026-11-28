import CmuxNextCompat
import CmuxNextWakeups
import Darwin
import Foundation
import Testing

/// A cancelled or replaced deadline must not wake the process later (app idle, cmux20-bench, 2026-11-27: the app at
/// 3.14/s against a 1.0/s budget). A `DemandTimer` slept in a `Task`, and Swift's `Task.sleep` cannot take back
/// the dispatch timer under it: cancel ends the sleep at once, yet that timer still fires at the old deadline and
/// wakes a thread, which macOS counts as a timer wakeup of the app. So every reset, cancel and ride on another wake
/// (``WakeCoalescer``, "coalesced" in the ledger) still cost the wakeup it was meant to save.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct DemandTimerCancelWakeupTests {
    /// The process's timer and package-idle wakeups so far (what `top`'s IDLEW and the idle bench count).
    static func wakeups() -> UInt64 {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard status == 0 else { return 0 }
        return info.ri_interrupt_wkups &+ info.ri_pkg_idle_wkups
    }

    /// Wakeups over `seconds` of rest after `body`.
    static func wakeups(over seconds: Double, after body: () -> Void) async throws -> UInt64 {
        body()
        let before = wakeups()
        try await Task.sleep(for: .seconds(seconds))
        return wakeups() &- before
    }

    /// 40 deadlines 1.0 s to 2.2 s out, spread so that no two share one kernel timer fire.
    static let delays = (0..<40).map { Duration.milliseconds(1_000 + 30 * $0) }

    @Test func cancelledDeadlinesOnTheSystemClockNeverWakeTheProcess() async throws {
        let rest = try await Self.wakeups(over: 2.5) {}
        let timers = Self.delays.map { delay in
            let timer = DemandTimer(owner: "cancel-wakeup-test", ledger: WakeupLedger())
            timer.schedule(after: delay) {}
            return timer
        }
        // Each sleep has begun (a cancel before that never armed a kernel timer).
        try await Task.sleep(for: .milliseconds(300))
        let cancelled = try await Self.wakeups(over: 2.5) { timers.forEach { $0.cancel() } }
        #expect(cancelled < rest + 10, "40 cancelled deadlines woke the process \(cancelled) times; at rest \(rest)")
    }

    @Test func aReplacedDeadlineOnTheSystemClockWakesTheProcessOnce() async throws {
        let rest = try await Self.wakeups(over: 2.5) {}
        let timer = DemandTimer(owner: "replace-wakeup-test", ledger: WakeupLedger())
        let fired = FireCount()
        var replaced: UInt64 = 0
        for delay in Self.delays {
            timer.schedule(after: delay) { fired.add() }
            // The sleep this schedule replaces had begun.
            try await Task.sleep(for: .milliseconds(5))
        }
        replaced = try await Self.wakeups(over: 3.5) {}
        #expect(fired.count == 1)
        #expect(replaced < rest + 12, "39 replaced deadlines woke the process \(replaced) times; at rest \(rest)")
    }
}

private nonisolated final class FireCount: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func add() { value.withLock { $0 += 1 } }
}

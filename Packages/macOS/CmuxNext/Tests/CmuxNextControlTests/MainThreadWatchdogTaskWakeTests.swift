@testable import CmuxNextControl
import CmuxNextWakeups
import CoreFoundation
import Darwin
import Foundation
import CmuxNextCompat
import Testing

/// The board's task-start wake reaches the watchdog thread even when it comes before that thread
/// enters its wait (PL-main's condition for the kqueue alarm, 2026-10-24): the alarm's user event
/// stays triggered until a wait reads it, so the thread re-reads the running task at once and
/// samples it when it crosses its budget. A lost wake would leave the thread in its 600 ms wait
/// past the end of a 40 ms task, and the over-budget record would have no stack.
@Suite(.serialized, .timeLimit(.minutes(1))) struct MainThreadWatchdogTaskWakeTests {
    #if DEBUG
    @MainActor
    @Test func aTaskWakeBeforeTheWaitIsNotLost() throws {
        // Threshold 1 s: the heartbeat's own check is 600 ms away, far past the task.
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .seconds(1), logStalls: false))
        let board = MainTaskBoard()
        watchdog.attach(board: board, recordTaskBudgets: true)
        watchdog.taskSampler.withLock { $0 = ThreadStackSampler(thread: mach_thread_self()) }
        watchdog.running.store(true, ordering: .releasing)
        let owner = board.internOwner("wakeBeforeWait")
        let began = Atomic<Bool>(false)
        let token = Mutex<MainTaskBoard.SpanToken?>(nil)
        // On the watchdog thread, after it read the board (no task) and right before its first
        // bounded wait: the task starts, so the board's wake comes before the thread waits.
        watchdog.beforeWaitForTesting.withLock {
            $0 = { nanos in
                guard nanos != nil, !began.load(ordering: .acquiring) else { return }
                let started = board.beginSpan(.input, owner: owner, budgetNanos: 10_000_000,
                                              startNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
                token.withLock { $0 = started }
                began.store(true, ordering: .releasing)
            }
        }
        // The main thread is awake (a turn began) before the watchdog thread first looks.
        watchdog.heartbeat(.afterWaiting)
        let thread = Thread { watchdog.watch(sampler: nil) }
        thread.start()
        defer { watchdog.stop() }
        // The main thread stays on CPU (the sample needs it running): a bounded spin until the task began.
        let deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 5_000_000_000
        while !began.load(ordering: .acquiring), clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < deadline {}
        let span = try #require(token.withLock { $0 }, "the watchdog thread never reached a bounded wait")
        spinForTestAction(milliseconds: 40)
        board.endSpan(span, nowNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        let record = try #require(watchdog.overBudget.records().first, "no over-budget record for a 40 ms task with a 10 ms budget")
        #expect(record.details["task_owner"] == .string("wakeBeforeWait"))
        #expect(!record.addresses.isEmpty, "the wake before the wait was lost: the task ended before the watchdog sampled it")
        #expect(record.frames.contains { $0.symbol?.contains("spinForTestAction") == true },
                "frames: \(record.frames.prefix(8).map(\.description))")
    }

    /// The alarm itself: a wake with no wait running ends the next wait at once.
    @Test func aWakeWithNoWaiterEndsTheNextWait() {
        let alarm = MainThreadWatchdogAlarm()
        #expect(alarm.isAvailable)
        alarm.wake()
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        alarm.wait(nanos: 5_000_000_000)
        #expect(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start < 1_000_000_000, "the wake was lost; the wait ran to its 5 s limit")
    }
    #endif
}

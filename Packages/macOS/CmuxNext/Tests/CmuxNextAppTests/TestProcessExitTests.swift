import AppKit
import CmuxNextCompat
import CmuxNextTestExitTrace
import Foundation
import Testing

/// The Swift test helper ended with status 0 in the middle of this target, hundreds of tests
/// "started and never finished" and no crash report: a quit scheduled on the run loop ran
/// `NSApp.terminate`, which is `exit(0)` in a process whose app never ran, as soon as any test
/// spun the main run loop.
@MainActor
struct TestProcessExitTests {
    @Test func aQuitInATestProcessIsRefusedAndNamesWhereItWasAsked() {
        _ = NSApplication.shared
        #expect(!NSApp.isRunning)
        NSApplication.terminateFromRunLoop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        // Still running: the quit was refused, not exit(0).
        #expect(NSApplication.refusedTerminations.contains { $0.hasPrefix("CmuxNextAppTests/TestProcessExitTests.swift:") })
    }

    @Test func anExitOfTheTestProcessPrintsItsStack() {
        #expect(cmux_next_test_exit_trace_installed() == 1)
    }

    /// swift-testing's async main runs the main run loop with `CFRunLoopRun()` and calls `exit(0)`
    /// when it returns, so a stop that reached it ended the whole run with status 0 and no summary
    /// (every feat-cmux-next tip, 2026-10-28). The guard keeps a pass of its own under it.
    @Test func theTestHelperKeepsItsOutermostMainRunLoopRunning() async {
        #expect(cmux_next_test_run_loop_guard_installed() == 1)
        #expect(cmux_next_test_run_loop_guard_running() == 1)
    }

    /// A stop of the main run loop from a main-actor job, as `NSApp.postEvent` makes one. Without
    /// the guard the process exits 0 at the next suspension and this test never finishes, which
    /// the swift test job reports as a run with no summary.
    @Test func aStopOfTheMainRunLoopDoesNotEndTheTestRun() async {
        CFRunLoopStop(CFRunLoopGetMain())
        // Suspend until the main run loop runs a default-mode block: the stopped pass must return
        // first, so the outermost loop would have returned (and the process exited) by then.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) { done.resume() }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        // Reaching here is the proof. Which pass the stop ended depends on who ran this job (the guard's
        // pass, or another suite's nested one), so the guard's stop count is not asserted.
        #expect(cmux_next_test_run_loop_guard_running() == 1)
    }
}

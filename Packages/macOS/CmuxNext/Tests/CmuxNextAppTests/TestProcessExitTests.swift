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

    /// The other way a test run ends in the middle with status 0: something stops the main run
    /// loop while its outermost run is the current one. `swift_task_asyncMainDrainQueue` calls
    /// `exit(0)` the moment that run returns, so the tests in flight never report and there is no
    /// summary line (run 40317841968: 2793 tests started and never finished). This test takes that
    /// stop for real, from a timer on the main run loop, and the assertions below run at all only
    /// because the process is still alive. With `CMUX_NEXT_TEST_RUNLOOP_GUARD=0` the same binary
    /// ends here instead.
    @Test func aStopOfTheOutermostRunLoopDoesNotEndTheTestRun() async throws {
        // Deliberately NOT a #require on the guard being installed. With
        // CMUX_NEXT_TEST_RUNLOOP_GUARD=0 this test must reach the stop and the process must die of
        // it, because that is the only red that proves anything: a red that only says "the guard
        // was switched off" would be the switch testing itself (cmux#25391 review, 2026-10-26).
        let guarded = cmux_next_test_runloop_guard_installed() == 1
        // The whole design rests on the drain queue's run not being the innermost one, so that is
        // checked rather than assumed: its run, plus the one the guard holds inside it. A
        // toolchain that stopped running the main loop here, or ran it in a mode outside the
        // common modes where the counting observer cannot see it, fails on this line and says so.
        if guarded { #expect(cmux_next_test_runloop_guard_depth() >= 2) }

        // Three stops, not one: the first shape of this fix survived exactly one (run 40321954380)
        // and one stop would have called that a pass.
        let wanted = 3
        let before = cmux_next_test_runloop_guard_reentries()
        defer { cmux_next_test_runloop_guard_stop_probing() }
        cmux_next_test_runloop_guard_stop_outermost(Int32(wanted))
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline,
              cmux_next_test_runloop_guard_stopped_outermost() < Int32(wanted)
                  || cmux_next_test_runloop_guard_reentries() - before < Int32(wanted) {
            try await Task.sleep(for: .milliseconds(20))
        }
        // The stops landed at all only because the process is still running to count them, and
        // each was followed by a restart: survived, not merely attempted.
        #expect(cmux_next_test_runloop_guard_stopped_outermost() == Int32(wanted))
        #expect(cmux_next_test_runloop_guard_reentries() - before >= Int32(wanted))
    }
}

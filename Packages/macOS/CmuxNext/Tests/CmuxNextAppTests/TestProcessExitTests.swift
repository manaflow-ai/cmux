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
}

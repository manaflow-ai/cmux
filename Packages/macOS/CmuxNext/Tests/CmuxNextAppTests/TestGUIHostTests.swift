import AppKit
import CmuxNextTestGUIHost
import Foundation
import Testing

/// The test process runs as an app (CmuxNextTestGUIHost, started when the test bundle loads). It always dispatches
/// NSApp's events; in a run that asks for a GUI (`CMUX_CI_CONSOLE_SESSION=1`, set by the fleet worker on every
/// gui-session-v1 step, or `CMUX_TEST_REQUIRE_GUI=1`) it also finishes launching, is active, and a window it orders
/// front becomes key; otherwise it leaves a person's focus alone. Before it, under `swift test` NSApp never
/// dispatched its events, so no window became key and the process never became active (fleet probe 0ba1d205).
///
/// One test, no trait skip: the lane fails a suite on any skipped test when `CMUX_TEST_REQUIRE_GUI=1`.
@MainActor @Suite(.serialized)
struct TestGUIHostTests {
    nonisolated static var asksForGUI: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CMUX_CI_CONSOLE_SESSION"] == "1" || environment["CMUX_TEST_REQUIRE_GUI"] == "1"
    }

    @Test func theHostDispatchesEventsAndActivatesOnlyWhenTheRunAsksForAGUI() async throws {
        // The host starts on the main queue's first turn; a test runs after it.
        for _ in 0..<200 where cmux_next_test_gui_host_running() == 0 { await Task.yield() }
        #expect(cmux_next_test_gui_host_running() == 1, "the GUI test host never started")
        guard Self.asksForGUI else {
            #expect(cmux_next_test_gui_host_activated() == 0, "the host activated the test process with no GUI opt-in")
            return
        }
        #expect(cmux_next_test_gui_host_activated() == 1, "the run asked for a GUI but the host did not activate")
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 320, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        // AppKit makes it key when it handles the order's events, on a later main turn.
        let end = ContinuousClock.now + .seconds(5)
        while !window.isKeyWindow, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        #expect(NSApp.isActive, "the test process is not the active app")
        #expect(window.isKeyWindow, "a window the test process ordered front never became key")
    }
}

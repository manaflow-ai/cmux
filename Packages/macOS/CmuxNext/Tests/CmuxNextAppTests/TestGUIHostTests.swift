import AppKit
import CmuxNextTestGUIHost
import Foundation
import Testing

/// The test process runs as an app (CmuxNextTestGUIHost, started when the test bundle loads). It always dispatches
/// NSApp's events; with `CMUX_TEST_REQUIRE_GUI=1` (the fleet's gui-session-v1 steps) it also finishes launching, is
/// active, and a window it orders front becomes key. Before it, under `swift test` NSApp never dispatched its events,
/// so no window became key and the process never became active (fleet probe 0ba1d205, cmux11s).
@MainActor @Suite(.serialized)
struct TestGUIHostTests {
    /// The run asked for a GUI; a person's own `swift test` does not activate and steal their focus.
    nonisolated static var requiresGUI: Bool { ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1" }

    /// The host starts on the main queue's first turn; a test runs after it.
    private func hostStarted() async -> Bool {
        for _ in 0..<200 where cmux_next_test_gui_host_running() == 0 { await Task.yield() }
        return cmux_next_test_gui_host_running() == 1
    }

    @Test func theHostDispatchesEventsInEveryRun() async {
        #expect(await hostStarted(), "the GUI test host never started")
    }

    @Test(.enabled("needs CMUX_TEST_REQUIRE_GUI=1: the host activates the test process only when the run asks for a GUI",
                   { Self.requiresGUI }))
    func withAGUIRunTheProcessIsActiveAndAWindowBecomesKey() async throws {
        #expect(await hostStarted(), "the GUI test host never started")
        #expect(cmux_next_test_gui_host_activated() == 1, "CMUX_TEST_REQUIRE_GUI=1 but the host did not activate")
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

    /// Without the opt-in the host makes no app of the process: a person's focus stays where it is.
    @Test(.disabled("only meaningful without CMUX_TEST_REQUIRE_GUI", { Self.requiresGUI }))
    func withoutAGUIRunTheHostDoesNotActivate() async {
        #expect(await hostStarted(), "the GUI test host never started")
        #expect(cmux_next_test_gui_host_activated() == 0, "the host activated the test process with no GUI opt-in")
    }
}

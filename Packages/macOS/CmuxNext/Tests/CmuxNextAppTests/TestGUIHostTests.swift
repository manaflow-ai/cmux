import AppKit
import CmuxNextTestGUIHost
import Testing

/// The test process is an app (CmuxNextTestGUIHost, started when the test bundle loads): it finished launching, it is
/// active, and a window it orders front becomes key. Before it, under `swift test` NSApp never dispatched its
/// events, so no window became key and the process never became active (fleet probe 0ba1d205, cmux11s).
@MainActor @Suite(.serialized)
struct TestGUIHostTests {
    @Test func theTestProcessIsARunningActiveAppAndAWindowBecomesKey() async throws {
        // The host starts on the main queue's first turn; a test runs after it.
        for _ in 0..<200 where cmux_next_test_gui_host_running() == 0 { await Task.yield() }
        #expect(cmux_next_test_gui_host_running() == 1, "the GUI test host never started")
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

import AppKit
@testable import CmuxNextApp
import CmuxNextTestSupport
import Testing

/// A `debug.mouse` scroll carries the time it happened, as a real trackpad event does. The column
/// scroll reducer reads each gesture sample's `event.timestamp` for the release velocity, so a scroll
/// with timestamp 0 (a fresh CGEvent on macOS 27) made every bench gesture release at the 1/120 s
/// floor: 118080 pt/s instead of 2880 pt/s for a 24 pt step each 120 Hz frame, a fling a person never
/// makes (B1 A/B, #32369). The command-pan bench measured that release.
@MainActor @Suite(.serialized, .closesItsWindows)
struct DebugMouseScrollTimestampTests {
    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func aGestureScrollCarriesTheTimeItWasMade() throws {
        let window = Self.window()
        defer { window.close() }
        let before = ProcessInfo.processInfo.systemUptime
        let event = try #require(DebugMouse.scroll(atBase: NSPoint(x: 100, y: 100), in: window, dx: 24, dy: 0, phase: "changed"))
        let after = ProcessInfo.processInfo.systemUptime
        #expect(event.timestamp > 0, "the synthesized scroll has no timestamp")
        // The event clock and the uptime clock read the same boot clock; allow for their rounding.
        #expect(event.timestamp >= before - 0.05 && event.timestamp <= after + 0.05,
                "timestamp \(event.timestamp) is not the time it was made (\(before)...\(after))")
    }

    @Test func gestureScrollsMadeApartCarryThatGap() async throws {
        let window = Self.window()
        defer { window.close() }
        let first = try #require(DebugMouse.scroll(atBase: NSPoint(x: 100, y: 100), in: window, dx: 24, dy: 0, phase: "began"))
        // The test needs real time to pass between the two events: the gap is what it checks.
        try await Task.sleep(for: .milliseconds(20))
        let second = try #require(DebugMouse.scroll(atBase: NSPoint(x: 100, y: 100), in: window, dx: 24, dy: 0, phase: "changed"))
        let gap = second.timestamp - first.timestamp
        #expect(gap >= 0.015 && gap <= 0.5, "two scrolls at least 20 ms apart are \(gap) s apart")
    }
}

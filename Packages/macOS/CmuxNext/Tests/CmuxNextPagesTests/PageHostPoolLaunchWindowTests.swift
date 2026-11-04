import AppKit
import CmuxNextCompat
@testable import CmuxNextPages
import CmuxNextTestSupport
import Testing

/// The first Settings open after launch (perceived speed, 2026-10-15): the pool parks its
/// Settings spare in a main window, and it learned of one only when a window became key. A window
/// that showed before the pool started, or that never became key (an app launched in the
/// background, the capture slots), left the pool without a target: it built no spare, and the
/// first Cmd-, loaded a fresh page (the pane kept the previous page for about 400 ms).
@MainActor @Suite(.serialized, .closesItsWindows) struct PageHostPoolLaunchWindowTests {
    @Test func aMainWindowShownBeforeStartTakesTheSpare() {
        let window = Self.shownWindow()
        defer { window.close() }
        let pool = PageHostPool(memoryPressure: MemoryPressureEvents(source: ManualMemoryPressureSource()), activity: { 0 }, isTrackingMenu: { false })
        defer { pool.dropSpare() }
        pool.start(isMainWindow: { $0 === window }, fallback: { _ in nil })
        pool.noteLikely()
        #expect(pool.target === window, "the pool started with a main window on screen and parked its spare nowhere")
    }

    /// The launch window shows once the daemon's workspaces load, after the pool started, and an
    /// app launched in the background never makes it key. A second window leaves the spare where it is.
    @Test func aMainWindowShownAfterStartTakesTheSpare() {
        let pool = PageHostPool(memoryPressure: MemoryPressureEvents(source: ManualMemoryPressureSource()), activity: { 0 }, isTrackingMenu: { false })
        defer { pool.dropSpare() }
        pool.start(isMainWindow: { _ in false }, fallback: { _ in nil })
        pool.noteLikely()
        let window = Self.shownWindow()
        defer { window.close() }
        pool.windowDidAppear(window)
        #expect(pool.target === window)
        let second = Self.shownWindow()
        defer { second.close() }
        pool.windowDidAppear(second)
        #expect(pool.target === window, "a second window took the spare from a window on screen")
    }

    static func shownWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -4_000, y: -4_000, width: 900, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }
}

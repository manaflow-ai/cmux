#if DEBUG
import AppKit
@testable import CmuxNextApp
import Testing

/// `debug.mouse` `button: "middle"` posts AppKit's middle-button events
/// (`otherMouse*`, `buttonNumber` 2), the events a sidebar workspace row
/// closes its workspace on (MIDDLE-CLICK-CLOSES-WORKSPACE), so builders can
/// test a middle click through the socket.
@MainActor
@Suite struct DebugMouseButtonTests {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func middleButtonPostsOtherMouseEventsWithButtonNumberTwo() throws {
        let types = DebugMouse.eventTypes(button: "middle")
        #expect(types.down == .otherMouseDown)
        #expect(types.up == .otherMouseUp)
        #expect(types.dragged == .otherMouseDragged)
        let window = window()
        let down = try #require(DebugMouse.mouse(types.down, at: NSPoint(x: 20, y: 20), in: window, flags: [], clicks: 1))
        let up = try #require(DebugMouse.mouse(types.up, at: NSPoint(x: 20, y: 20), in: window, flags: [], clicks: 1))
        #expect(down.buttonNumber == 2)
        #expect(up.buttonNumber == 2)
        #expect(up.pressure == 0)
        #expect(down.windowNumber == window.windowNumber)
    }

    /// The views hit-test the window-local point; a Mac without a display
    /// maps the copied event's point through a screen it does not have.
    @Test(.requiresGUISession) func middleButtonEventsKeepTheWindowLocalPoint() throws {
        let types = DebugMouse.eventTypes(button: "middle")
        let window = window()
        let down = try #require(DebugMouse.mouse(types.down, at: NSPoint(x: 20, y: 20), in: window, flags: [], clicks: 1))
        #expect(down.type == .otherMouseDown)
        #expect(down.locationInWindow == NSPoint(x: 20, y: 180))
    }

    @Test func leftAndRightKeepTheirEvents() {
        #expect(DebugMouse.eventTypes(button: nil).down == .leftMouseDown)
        #expect(DebugMouse.eventTypes(button: "left").up == .leftMouseUp)
        #expect(DebugMouse.eventTypes(button: "right").down == .rightMouseDown)
    }
}
#endif

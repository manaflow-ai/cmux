import AppKit
import CmuxNextDesign
import Testing

/// `NSEvent.screenLocation` reads the window server's point of an event that has a window, so the
/// point holds while that window moves under the pointer (a panel dragged by its own handler).
@MainActor @Suite(.serialized)
struct NSEventScreenLocationTests {
    @Test func aWindowedEventKeepsItsScreenPointWhileItsWindowMoves() throws {
        _ = NSApplication.shared
        let primary = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(contentRect: CGRect(x: primary.maxX - 460, y: primary.minY + 60, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let point = CGPoint(x: window.frame.minX + 140, y: window.frame.minY + 120)
        // Quartz's global coordinates start at the primary display's top left.
        let quartz = CGPoint(x: point.x, y: primary.height - point.y)
        let cgEvent = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: quartz, mouseButton: .left))
        cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        let event = try #require(NSEvent(cgEvent: cgEvent))
        try #require(event.window === window, "the event has the window, so the window server's point is read")

        #expect(event.screenLocation == point)
        #expect(event.screenLocation == window.convertPoint(toScreen: event.locationInWindow), "before a move both agree")

        window.setFrameOrigin(CGPoint(x: window.frame.minX - 200, y: window.frame.minY))
        #expect(event.screenLocation == point, "the window moved; the event's screen point did not")
        #expect(window.convertPoint(toScreen: event.locationInWindow) != point, "the window-relative point moved with the window")
    }

    @Test func anEventWithNoWindowIsAlreadyInScreenPoints() throws {
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 321, y: 123), modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(event.screenLocation == CGPoint(x: 321, y: 123))
    }
}

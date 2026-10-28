import AppKit
@testable import CmuxNextDesign
import Testing

/// An enter or exit sets hover from its own point, not from the live cursor: the
/// event a tracking area sends says where the pointer crossed, and the window's targets hover from
/// that point wherever the real mouse rests.
@MainActor @Suite(.serialized)
struct PointerHoverEventPointTests {
    @Test func anEnterHoversFromItsPointAndAnExitClearsFromItsPoint() throws {
        _ = NSApplication.shared
        let screen = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(contentRect: CGRect(x: screen.maxX - 460, y: screen.minY + 60, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Above the test host's other windows there, so the topmost check finds this one.
        window.level = .floating
        let view = NSView(frame: CGRect(x: 100, y: 100, width: 80, height: 40))
        window.contentView?.addSubview(view)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let hover = PointerHover(view)

        hover.mouseEntered(with: try event(.mouseEntered, at: CGPoint(x: 140, y: 120), in: window))
        #expect(hover.isHovering, "the enter's point is over the view")
        hover.mouseExited(with: try event(.mouseExited, at: CGPoint(x: 40, y: 20), in: window))
        #expect(!hover.isHovering, "the exit's point is off the view")
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    }
}

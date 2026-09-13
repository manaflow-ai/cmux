import AppKit
import CmuxCanvas
import Testing
@testable import CmuxCanvasUI

@MainActor
@Suite("Canvas tab context menu", .serialized)
struct CanvasTabContextMenuTests {
    @Test func menuTargetsTabUnderPointerWithoutSelectingIt() throws {
        let first = UUID()
        let second = UUID()
        let pane = CanvasPaneView(paneID: CanvasPaneID(rawValue: first))
        let delegate = CanvasPaneDelegateSpy()
        pane.delegate = delegate
        pane.updateChrome(CanvasPaneChrome(
            tabs: [
                CanvasTabChrome(id: first, title: "First tab", iconSystemName: "terminal"),
                CanvasTabChrome(id: second, title: "Second tab", iconSystemName: "terminal"),
            ],
            selectedTabId: second,
            isFocused: true,
            closeActionLabel: "Close"
        ))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 220),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = pane
        defer { window.close() }
        pane.layoutSubtreeIfNeeded()
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: pane.convert(CGPoint(x: 45, y: 15), to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        #expect(pane.menu(for: event) != nil)
        #expect(delegate.menuRequests == [first])
        #expect(delegate.focusRequests.isEmpty)
    }
}

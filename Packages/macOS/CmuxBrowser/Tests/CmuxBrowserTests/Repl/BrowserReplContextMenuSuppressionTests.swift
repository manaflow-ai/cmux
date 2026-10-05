import AppKit
import Testing

@testable import CmuxBrowser

/// An agent's click that opens a context menu (a right click, or a
/// Control-click, which WebKit treats as one) must not show cmux's native
/// menu, so it arms a suppression the menu uses up. A page that cancels the
/// `contextmenu` event leaves it armed; the person's next click that opens a
/// menu, by either gesture, must still get theirs.
@MainActor
@Suite struct BrowserReplContextMenuSuppressionTests {
    private func mouseDown(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    @Test func anAutomatedControlClickDoesNotShowTheNativeMenu() throws {
        var suppression = BrowserAutomationContextMenuSuppression()
        suppression.noteAutomatedMouseDown(try mouseDown(.leftMouseDown, .control))
        let used1 = suppression.consume()
        #expect(used1, "an agent's Control-click showed cmux's native context menu")
        suppression.noteAutomatedMouseDown(try mouseDown(.leftMouseDown))
        let used2 = suppression.consume()
        #expect(!used2, "a plain click armed a suppression no menu uses up")
    }

    @Test func thePersonsControlClickClearsAPreventedAutomatedClicksSuppression() throws {
        var suppression = BrowserAutomationContextMenuSuppression()
        // The page cancelled contextmenu: no menu used the suppression up.
        suppression.noteAutomatedMouseDown(try mouseDown(.rightMouseDown))
        suppression.noteUserMouseDown(try mouseDown(.leftMouseDown, .control))
        let used3 = suppression.consume()
        #expect(!used3, "the person's Control-click menu was swallowed")

        suppression.noteAutomatedMouseDown(try mouseDown(.rightMouseDown))
        suppression.noteUserMouseDown(try mouseDown(.rightMouseDown))
        let used4 = suppression.consume()
        #expect(!used4, "the person's right-click menu was swallowed")

        suppression.noteAutomatedMouseDown(try mouseDown(.rightMouseDown))
        suppression.noteUserMouseDown(try mouseDown(.leftMouseDown))
        let used5 = suppression.consume()
        #expect(used5, "a plain click, which opens no menu, let the agent's menu show")

        suppression.noteAutomatedMouseDown(try mouseDown(.rightMouseDown))
        suppression.cancelAll()
        let used6 = suppression.consume()
        #expect(!used6)
    }
}

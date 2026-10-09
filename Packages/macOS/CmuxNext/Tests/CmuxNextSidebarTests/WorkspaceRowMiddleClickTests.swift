import AppKit
import Testing
@testable import CmuxNextSidebar

/// MIDDLE-CLICK-CLOSES-WORKSPACE: a middle click on a workspace row closes
/// that workspace through the shared close intent (the row's x, so the same
/// confirmation); on a group row it does nothing.
@MainActor @Suite struct WorkspaceRowMiddleClickTests {
    final class Harness {
        let window: NSWindow
        let sidebar: SidebarView
        var intents: [SidebarIntent] = []

        init(deferred: Bool = true) {
            let model = SidebarModel(sections: fixture(), activeWorkspaceID: id("a"))
            sidebar = SidebarView(model: model)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.borderless], backing: .buffered, defer: deferred)
            window.isReleasedWhenClosed = false
            sidebar.frame = window.contentView.bounds
            window.contentView.addSubview(sidebar)
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.reload(animated: false)
            model.onIntent = { [unowned self] intent in self.intents.append(intent) }
        }

        var list: SidebarListView { sidebar.list }

        /// The middle of `key`'s row, in list coordinates.
        func point(_ key: SidebarRowKey) -> NSPoint {
            let frame = list.frame(for: list.displayed.row(for: key)!)
            return NSPoint(x: frame.midX, y: frame.midY)
        }

        func middleClick(down: SidebarRowKey, up: SidebarRowKey) {
            list.middleClick.pressDown(at: point(down), in: list)
            list.middleClick.pressUp(at: point(up), in: list)
        }
    }

    @Test func middleClickOnAWorkspaceRowClosesThatWorkspace() {
        let h = Harness()
        h.middleClick(down: .workspace(id("b")), up: .workspace(id("b")))
        #expect(h.intents == [.close([id("b")])])
    }

    @Test func middleClickClosesOnlyTheClickedRowNotTheSelection() {
        let h = Harness()
        h.list.model.toggleSelection(id("a"))
        h.list.model.toggleSelection(id("c"))
        h.middleClick(down: .workspace(id("b")), up: .workspace(id("b")))
        #expect(h.intents == [.close([id("b")])])
    }

    /// The events `debug.mouse` `button: "middle"` makes (`otherMouse*`,
    /// `buttonNumber` 2, copied through CGEvent), given to the view the
    /// window hit-tests at the row, close the row's workspace through the
    /// responder chain. (NSWindow.sendEvent did not reach the list in the GUI
    /// lane for a window that is not on screen; tests must not show one.) Needs a display:
    /// without one the copied event's point maps through a missing screen
    /// (the GUI lane sets CMUX_TEST_REQUIRE_GUI=1 and never skips).
    @Test(.enabled("needs a display (skipped in the headless lane)") {
        await MainActor.run { ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1" || !NSScreen.screens.isEmpty }
    })
    func middleButtonEventsAtTheRowCloseTheWorkspace() throws {
        let h = Harness(deferred: false)
        let at = h.list.convert(h.point(.workspace(id("b"))), to: nil)
        let frameView = try #require(h.window.contentView?.superview)
        let target = try #require(frameView.hitTest(frameView.convert(at, from: nil)))
        for type in [NSEvent.EventType.otherMouseDown, .otherMouseUp] {
            let made = try #require(NSEvent.mouseEvent(
                with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .otherMouseUp ? 0 : 1))
            // As debug.mouse makes them (DebugMouse.keepingWindowPoint): NSEvent.mouseEvent leaves
            // buttonNumber 0, the middle button is 2, and the copy is moved by what AppKit's mapping
            // through the window server's frame (not this unshown window's) got wrong.
            let cg = try #require(made.cgEvent?.copy())
            cg.setIntegerValueField(.mouseEventButtonNumber, value: 2)
            let first = try #require(NSEvent(cgEvent: cg))
            cg.location = CGPoint(x: cg.location.x + at.x - first.locationInWindow.x,
                                  y: cg.location.y - (at.y - first.locationInWindow.y))
            let event = try #require(NSEvent(cgEvent: cg))
            #expect(event.buttonNumber == 2)
            #expect(event.locationInWindow == at)
            if type == .otherMouseDown { target.otherMouseDown(with: event) } else { target.otherMouseUp(with: event) }
        }
        #expect(h.intents == [.close([id("b")])])
    }

    @Test func middleClickOnAGroupRowDoesNothing() {
        let h = Harness()
        h.middleClick(down: .group(g1), up: .group(g1))
        #expect(h.intents.isEmpty)
    }

    @Test func middlePressThatLeavesTheRowClosesNothing() {
        let h = Harness()
        h.middleClick(down: .workspace(id("a")), up: .workspace(id("b")))
        #expect(h.intents.isEmpty)
    }
}

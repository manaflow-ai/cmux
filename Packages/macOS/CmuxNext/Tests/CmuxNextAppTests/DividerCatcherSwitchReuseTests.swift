import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// SWITCH FRAMES SF-3 (Time Profiler of Cmd-2 between two 2-pane terminal workspaces, bench build, cmux23: the key
/// turn's handler is 11 ms of which DividerMouseCatchers.update is 2.5 ms). A workspace switch releases the old
/// workspace's overlay plane (its divider areas leave) and adopts the new one's (other divider ids) in the same turn,
/// so every switch closed the old divider's catcher panel and made a new window for the new divider. The panels are
/// reused across divider ids: a switch moves a panel, it makes no window.
@Suite(.serialized, .closesItsWindows)
@MainActor struct DividerCatcherSwitchReuseTests {
    /// A page window over the whole window, as the Chromium fork adds one: only an area a page covers gets a panel.
    static func page(over window: NSWindow) -> NSWindow {
        let page = NSWindow(contentRect: window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false
        window.addChildWindow(page, ordered: .above)
        return page
    }

    @Test func aSwitchToAnotherWorkspacesDividerMakesNoNewPanel() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 800, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderFrontRegardless()
        let page = Self.page(over: window)
        defer { window.removeChildWindow(page); page.close() }
        let catchers = DividerMouseCatchers(window: window)
        defer { catchers.teardown() }
        func area(_ id: String, x: CGFloat) -> LayoutMouseArea {
            LayoutMouseArea(id: id, rect: CGRect(x: x, y: 0, width: 8, height: 400), resizesColumns: true)
        }
        // Workspace 1 shows: its divider has a panel.
        catchers.update([area("ws1-divider", x: 400)], active: true)
        #expect(catchers.panelsMade == 1)
        // Cmd-2 in one turn: workspace 1's plane leaves (no areas), workspace 2's comes (its own divider id).
        catchers.update([], active: true)
        catchers.update([area("ws2-divider", x: 300)], active: true)
        #expect(catchers.panelsMade == 1, "a workspace switch made \(catchers.panelsMade - 1) new catcher window(s): every switch pays a window creation")
        #expect(catchers.framesInWindow.keys.sorted() == ["ws2-divider"], "only the shown divider has a panel: \(catchers.framesInWindow)")
        #expect(catchers.windowNumbers.count == 1, "one panel takes the mouse: \(catchers.windowNumbers)")
        // And back: still no new window.
        catchers.update([], active: true)
        catchers.update([area("ws1-divider", x: 400)], active: true)
        #expect(catchers.panelsMade == 1)
    }

    /// A divider that leaves while another stays: its panel is parked in the window with no size and no mouse.
    @Test func aParkedPanelTakesNoMouse() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 800, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderFrontRegardless()
        let page = Self.page(over: window)
        defer { window.removeChildWindow(page); page.close() }
        let catchers = DividerMouseCatchers(window: window)
        defer { catchers.teardown() }
        let a = LayoutMouseArea(id: "a", rect: CGRect(x: 200, y: 0, width: 8, height: 400), resizesColumns: true)
        let b = LayoutMouseArea(id: "b", rect: CGRect(x: 500, y: 0, width: 8, height: 400), resizesColumns: true)
        catchers.update([a, b], active: true)
        catchers.update([a], active: true)
        let children = (window.childWindows ?? []).compactMap { $0 as? DividerMousePanel }
        try #require(children.count == 2, "the parked panel stays a child of the window: \(children.count)")
        let parked = try #require(children.first { window.convertFromScreen($0.frame) != catchers.framesInWindow["a"] })
        #expect(parked.frame.size == .zero, "a parked panel has no size: \(parked.frame)")
        #expect(parked.ignoresMouseEvents, "a parked panel takes no mouse")
        let shown = try #require(children.first { !$0.ignoresMouseEvents })
        #expect(catchers.windowNumbers == [shown.windowNumber])
    }

    /// A panel parked while its pointer was over it (an enter with its cursor set still queued) forgets that enter:
    /// the next divider that reuses it starts from no enter and no queued cursor.
    @Test func aParkedPanelForgetsItsEnter() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 800, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderFrontRegardless()
        let page = Self.page(over: window)
        defer { window.removeChildWindow(page); page.close() }
        let catchers = DividerMouseCatchers(window: window)
        defer { catchers.teardown() }
        let a = LayoutMouseArea(id: "a", rect: CGRect(x: 200, y: 0, width: 8, height: 400), resizesColumns: true)
        let b = LayoutMouseArea(id: "b", rect: CGRect(x: 500, y: 0, width: 8, height: 400), resizesColumns: true)
        catchers.update([a, b], active: true)
        let panels = (window.childWindows ?? []).compactMap { $0 as? DividerMousePanel }
        let panelB = try #require(panels.first { window.convertFromScreen($0.frame) == catchers.framesInWindow["b"] })
        panelB.catcher.isPointerOver = { true }
        let enter = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: CGPoint(x: 4, y: 100), modifierFlags: [],
                                                        timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                                        trackingNumber: 0, userData: nil))
        panelB.catcher.mouseEntered(with: enter)
        try #require(panelB.catcher.pendingCursorSet != nil, "the enter queues a cursor set")
        catchers.update([a], active: true) // b's divider leaves while the pointer is over its panel
        #expect(panelB.catcher.pendingCursorSet == nil, "a parked panel kept its queued cursor set from the old divider")
    }
}

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
    @Test func aSwitchToAnotherWorkspacesDividerMakesNoNewPanel() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 800, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderFrontRegardless()
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
}

import AppKit
@testable import CmuxNextApp
import CmuxNextSidebar
import CmuxNextTabs
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// p03-rendering-096 (plans/cmux-next/chrome-parity/p03-rendering.md R6): the switch hides the outgoing
/// workspace in its turn and leaves it in the window, so a switch back to a recently hidden workspace
/// makes 0 `viewDidMoveToWindow` calls.
@MainActor @Suite(.serialized) struct HiddenWorkspaceStaysInWindowTests {
    /// Counts the times it enters and leaves a window, as a terminal or a page deep in a workspace would.
    final class WindowMoves: NSView {
        private(set) var moves = 0
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            moves += 1
        }
    }

    private func makeRoot() -> (NSWindow, WindowRootView) {
        _ = NSApplication.shared
        let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel(), mainWork: MainWorkScheduler(budget: MainFrameBudget())), revealDeadlines: .testing())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        settle(root)
        return (window, root)
    }

    private func settle(_ root: WindowRootView) {
        for _ in 0..<4 { root.layoutSubtreeIfNeeded() }
    }

    /// A workspace whose layout holds one probe, nested as a pane's content is.
    private func makeWorkspace() -> (WorkspaceContentView, WindowMoves) {
        let layout = NSView(), pane = NSView(), probe = WindowMoves()
        pane.addSubview(probe)
        layout.addSubview(pane)
        return (WorkspaceContentView(layoutView: layout, bar: TabStripView.testing(model: TabStripModel())), probe)
    }

    private func show(_ view: WorkspaceContentView, in root: WindowRootView) {
        root.show(view)
        settle(root)
    }

    @Test func switchingBackToARecentlyHiddenWorkspaceMovesNoViewIntoTheWindow() {
        let (window, root) = makeRoot()
        defer { window.close() }
        let (a, probeA) = makeWorkspace(), (b, probeB) = makeWorkspace(), (c, probeC) = makeWorkspace()
        for view in [a, b, c] { show(view, in: root) }
        let entered = [probeA.moves, probeB.moves, probeC.moves]
        #expect(entered == [1, 1, 1], "each workspace enters the window once, at its first show")
        #expect(a.isHidden && b.isHidden && !c.isHidden, "the outgoing workspace hides in the switch's turn")

        for view in [a, c, b, a, b, c] {
            show(view, in: root)
            #expect(!view.isHidden && view.window === window)
        }
        let moved = zip([probeA.moves, probeB.moves, probeC.moves], entered).map { $0 - $1 }
        #expect(moved == [0, 0, 0], "switches back to hidden workspaces moved views into or out of the window: \(moved)")
        #expect([a, b].allSatisfy { $0.isHidden && $0.superview === root.contentHost }, "hidden workspaces stay in the main pane")
    }
}

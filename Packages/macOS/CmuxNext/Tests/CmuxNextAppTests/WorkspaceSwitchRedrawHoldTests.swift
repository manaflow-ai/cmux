import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextSidebar
import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Leo 2026-10-20: "when I'm switching to and from workspaces, we shouldn't be having these wild-ass
/// layout shifts ... Already cached things just load immediately." A parked workspace keeps its size
/// while hidden; when the window or the sidebar changed meanwhile, its chats showed their last
/// frames at the old size on the first frame back, then jumped to the new one. The window keeps the
/// outgoing workspace until they drew at the new size; at the size it was parked at, a workspace
/// shows at once.
@MainActor @Suite(.serialized, .closesItsWindows) struct WorkspaceSwitchRedrawHoldTests {
    /// A chat's page: it drew before, and draws again at a new size when told to.
    final class DrawnPage: NSView, WorkspacePageRedrawing {
        var hasDrawnFrame = true
        private var waiting: [() -> Void] = []
        private(set) var asked = 0
        func whenRedrawn(_ body: @escaping () -> Void) {
            asked += 1
            waiting.append(body)
        }

        func redraw() {
            let callbacks = waiting
            waiting = []
            callbacks.forEach { $0() }
        }
    }

    static func root() -> (NSWindow, WindowRootView) {
        _ = NSApplication.shared
        let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        settle(root)
        return (window, root)
    }

    /// The window's chrome settles over its first passes (the titlebar band, the sidebar, then the
    /// main pane under them): a workspace parked before then keeps a size the pane no longer has.
    static func settle(_ root: WindowRootView) {
        for _ in 0..<4 { root.layoutSubtreeIfNeeded() }
    }

    /// A workspace whose layout is one page filling it.
    static func workspace(_ page: NSView) -> WorkspaceContentView {
        let layout = NSView()
        let view = WorkspaceContentView(layoutView: layout, bar: TabStripView(model: TabStripModel()))
        page.autoresizingMask = [.width, .height]
        layout.addSubview(page)
        return view
    }

    /// Shows `view` and lets the window lay it out, its page filling it.
    static func show(_ view: WorkspaceContentView, in root: WindowRootView) {
        root.show(view)
        settle(root)
        // The shown workspace fills the main pane, as a window's later passes leave it.
        if let host = view.superview { view.frame = host.bounds }
        view.layoutView.subviews.first?.frame = view.layoutView.bounds
    }

    @Test func aWorkspaceShownAgainAtAnotherSizeWaitsForItsPagesToRedraw() {
        let (window, root) = Self.root()
        defer { window.close() }
        let first = DrawnPage(), second = DrawnPage()
        let a = Self.workspace(first), b = Self.workspace(second)
        Self.show(a, in: root)
        Self.show(b, in: root)
        #expect(a.isHidden)
        // The window grows while A is parked.
        window.setContentSize(NSSize(width: 1240, height: 700))
        root.layoutSubtreeIfNeeded()
        root.show(a)
        #expect(first.asked == 1, "A's page is asked to draw at the new size")
        #expect(a.alphaValue == 0, "A stays out of sight until its page drew at the new size")
        #expect(!b.isHidden, "B stays on screen meanwhile: no frame of A at its old size")
        #expect(a.frame.size == b.frame.size, "A already has the size it shows at")
        first.redraw()
        #expect(a.alphaValue == 1)
        #expect(b.isHidden)
    }

    @Test func aWorkspaceShownAgainAtTheSizeItWasParkedAtShowsAtOnce() throws {
        let (window, root) = Self.root()
        defer { window.close() }
        let first = DrawnPage(), second = DrawnPage()
        let a = Self.workspace(first), b = Self.workspace(second)
        Self.show(a, in: root)
        Self.show(b, in: root)
        try #require(a.frame.size == b.frame.size, "parked at \(a.frame.size), shown at \(b.frame.size)")
        let host = try #require(a.superview)
        try #require(a.frame.size == host.bounds.size, "parked at \(a.frame), host \(host.frame) bounds \(host.bounds)")
        root.show(a)
        #expect(first.asked == 0)
        #expect(a.alphaValue == 1)
        #expect(b.isHidden)
    }

    @Test func aPageThatNeverDrewHoldsNoSwitch() {
        let (window, root) = Self.root()
        defer { window.close() }
        let first = DrawnPage(), second = DrawnPage()
        first.hasDrawnFrame = false
        let a = Self.workspace(first), b = Self.workspace(second)
        Self.show(a, in: root)
        Self.show(b, in: root)
        window.setContentSize(NSSize(width: 1240, height: 700))
        root.layoutSubtreeIfNeeded()
        root.show(a)
        // Its own loading state covers it at its final size (AgentPaneLoadingView).
        #expect(a.alphaValue == 1)
        #expect(b.isHidden)
    }
}

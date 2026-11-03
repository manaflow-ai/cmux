import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// A workspace with no pane has no tab strip, so its top row is titlebar space: a press there
/// moves the window (Leo, 2026-11-03: "there is nothinig at the top until you make a tab ... i also
/// can't drag from this top area at all").
@Suite(.closesItsWindows)
@MainActor struct EmptyWorkspaceTitlebarDragTests {
    @Test func aPressInTheEmptyWorkspacesTopRowMovesTheWindow() throws {
        _ = NSApplication.shared
        let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel()))
        let window = ShellWindow(contentRect: root.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        defer { window.close() }
        let content = WorkspaceContentView(layoutView: NSView(frame: .zero), bar: TabStripView(model: TabStripModel()))
        let empty = EmptyWorkspaceView()
        content.showEmpty(empty)
        root.show(content)
        root.layoutSubtreeIfNeeded()
        content.layoutSubtreeIfNeeded()

        let band = TitlebarDragPolicy.bandRect(in: window)
        try #require(band.height > 0, "the window has a titlebar band")
        let frameView = try #require(window.contentView?.superview)
        let shown = empty.convert(empty.bounds, to: nil)
        // The points of the band the empty view takes the press at (the sidebar and the lights take theirs).
        let points = stride(from: shown.minX + 2, to: shown.maxX - 2, by: 8).map { CGPoint(x: $0, y: band.midY) }
            .filter { point in frameView.hitTest(frameView.convert(point, from: nil)).map { $0.isDescendant(of: empty) } ?? false }
        try #require(!points.isEmpty, "the empty workspace reaches the top row")

        let staying = points.filter { TitlebarDragPolicy.decide(at: $0, in: window) != .movesWindow }
        #expect(staying.isEmpty, "a press stays put at \(staying)")
    }
}

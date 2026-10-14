import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextSidebar
import Testing

/// Edge containers batch 1 (Leo 2026-10-12, "the bottom-edge rounding"): the curved main pane
/// sits the gutter in from the window's edges, and its corners used a fixed 8 pt radius. At the
/// window's bottom corners that curve did not follow the window's own (about 16 pt), so the gutter
/// pinched and widened around each corner. The pane's corners are concentric with the window's:
/// the window radius less the gutter. Since Leo's 2026-10-13 call the pane meets the window edge
/// (no gutter), so its corners are the window's own and the two read as one outline.
@MainActor struct MainPaneWindowCornerTests {
    func root() -> (NSWindow, WindowRootView) {
        _ = NSApplication.shared
        let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        return (window, root)
    }

    @Test func theMainPaneCornersAreTheWindowCorners() throws {
        let (window, root) = root()
        defer { window.close() }
        let windowRadius = CEFClipShape.windowCornerRadius(window)
        try #require(Metrics.mainPaneCurved && windowRadius > 0, "a curved main pane in a window with round corners")
        #expect(root.contentHost.layer?.cornerRadius == windowRadius, "the pane's corner is the window's own")
    }
}

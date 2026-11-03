import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextSidebar
import Testing

extension MainPaneGutterSuites {
    /// Edge containers batch 1 (Leo 2026-10-12, "the bottom-edge rounding"): the curved main pane
    /// sits the gutter in from the window's edges, and its corners used a fixed 8 pt radius. At the
    /// window's bottom corners that curve did not follow the window's own (about 16 pt), so the
    /// gutter pinched and widened around each corner. The pane's corners are concentric with the
    /// window's: the window radius less the gutter. With the gutter at 0 (the Debug Settings flush
    /// opt-in) they are the window's own.
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

        @Test func theMainPaneCornersAreConcentricWithTheWindowCorners() throws {
            let (window, root) = root()
            defer { window.close() }
            let windowRadius = CEFClipShape.windowCornerRadius(window)
            let gutter = Metrics.mainPaneGutter
            try #require(Metrics.mainPaneCurved && windowRadius > gutter, "a curved main pane in a window with round corners")
            #expect(gutter > 0, "the default keeps a gutter at the window edges")
            // Lawrence 2026-10-31 ("round the pane bg thing more"): Helium's 14 pt content corner,
            // never rounder than the window's own.
            #expect(root.contentHost.layer?.cornerRadius == min(Metrics.heliumContentCornerRadius, windowRadius),
                    "the pane's corner is Helium's content corner")
        }

        /// Flush (gutter 0): the pane's corners are the window's own, so the two are one outline.
        @Test func withNoGutterTheMainPaneCornersAreTheWindowCorners() throws {
            try MainPaneGutterSuites.withGutter(0) {
                let (window, root) = root()
                defer { window.close() }
                let windowRadius = CEFClipShape.windowCornerRadius(window)
                try #require(Metrics.mainPaneCurved && windowRadius > 0, "a curved main pane in a window with round corners")
                #expect(root.contentHost.layer?.cornerRadius == windowRadius, "the pane's corner is the window's own")
            }
        }
    }
}

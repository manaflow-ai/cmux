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
    /// opt-in) they are the window's own. Each test pins the curved chrome style it reads
    /// (`MainPaneGutterSuites.onCurvedMainPane`): a settings load elsewhere in the run leaves the
    /// process-wide style flat.
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
            try MainPaneGutterSuites.onCurvedMainPane {
                let (window, root) = root()
                defer { window.close() }
                let windowRadius = CEFClipShape.windowCornerRadius(window)
                let gutter = Metrics.mainPaneGutter
                try #require(Metrics.mainPaneCurved && windowRadius > gutter, "a curved main pane in a window with round corners")
                #expect(gutter > 0, "the default keeps a gutter at the window edges")
                // Lawrence 2026-11-04: the one corner radius of panes and tabs, never rounder than the window's own;
                // 2026-11-05: its default is the omnibar's 8 pt, never rounder than concentric with the window.
                #expect(root.contentHost.layer?.cornerRadius == min(Metrics.densityPaneCornerRadius, windowRadius),
                        "the pane's corner is the one corner radius")
                #expect(Metrics.densityPaneCornerRadius <= windowRadius - gutter,
                        "the default main pane is no rounder than concentric with the window")
            }
        }

        /// The main pane keeps clear of the window's lit rim only where the window has one: a titled
        /// window, not a borderless one (a fullscreen window is square and has none either).
        @Test func onlyAWindowWithARimKeepsTheMainPaneInsideIt() {
            func window(_ style: NSWindow.StyleMask) -> NSWindow {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: style, backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                return window
            }
            let titled = window([.titled]), borderless = window([.borderless])
            defer { titled.close(); borderless.close() }
            #expect(Metrics.windowEdgeInset(0, in: titled) == PaneTabRowRim.height, "flush: the rim's width")
            #expect(Metrics.windowEdgeInset(6, in: titled) == 6, "a gutter already clears the rim")
            #expect(Metrics.windowEdgeInset(0, in: borderless) == 0, "a borderless window has no rim")
            #expect(Metrics.windowEdgeInset(0, in: nil) == 0, "no window yet")
        }

        /// Flush (gutter 0): the pane's corners sit just inside the window's lit rim, concentric with the
        /// window's own (Leo 2026-11-07: "the window at the edges, it just doesn't show through").
        @Test func withNoGutterTheMainPaneCornersAreTheWindowCorners() throws {
            try MainPaneGutterSuites.onCurvedMainPane {
                try MainPaneGutterSuites.withGutter(0) {
                    let (window, root) = root()
                    defer { window.close() }
                    let windowRadius = CEFClipShape.windowCornerRadius(window)
                    try #require(Metrics.mainPaneCurved && windowRadius > 0, "a curved main pane in a window with round corners")
                    #expect(root.contentHost.layer?.cornerRadius == windowRadius - PaneTabRowRim.height,
                            "the pane's corner is concentric with the window's, inside its rim")
                }
            }
        }
    }
}

import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextSidebar
import Testing

extension MainPaneGutterSuites {
    /// Edge containers batch 1 (Leo 2026-10-12, "odd padding all around the window and panes"): the
    /// window stacked insets. The curved main pane sat a 6 pt gutter in from the window, every pane
    /// sat another 2 pt (plus a 2 pt column gap at the sides) inside it as its own outlined, rounded
    /// box, and beside the sidebar the gutter came on top of the sidebar's own 6 pt row inset. Inside
    /// the main pane panes are flush and told apart by one line. The gutter itself runs on every side
    /// of the main pane, the sidebar's too (Lawrence 2026-10-14: a margin all round, as in Helium).
    /// With the gutter at 0 (the Debug Settings flush opt-in, 2026-10-14) the pane meets the window
    /// edges and the sidebar.
    @MainActor struct MainPaneOneInsetTests {
        /// Runs `body` on the in-memory default chrome style, whose main pane is curved. The style is
        /// process-wide: a settings load in a suite that runs alongside leaves it at the file
        /// default `flat-sidebar-line` (no card, ChromeStyleSetting.fallback), so pin it here.
        func onCurvedMainPane<T>(_ body: () throws -> T) rethrows -> T {
            let design = DesignSettings.shared
            let before = design.chromeStyle
            design.chromeStyle = .default
            defer { design.chromeStyle = before }
            return try body()
        }

        func root(sidebarHidden: Bool) -> (NSWindow, WindowRootView) {
            _ = NSApplication.shared
            let model = SidebarModel()
            if sidebarHidden { model.presentation = .hidden }
            let root = WindowRootView(sidebar: SidebarContainerView(model: model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.contentView = root
            if sidebarHidden {
                root.sidebar.isHidden = true
                root.sidebarHidden = true
            }
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
            return (window, root)
        }

        @Test func panesInsideTheMainPaneAreFlushWithOneLineBetweenThem() throws {
            try onCurvedMainPane {
                try #require(Metrics.mainPaneCurved, "the curved main pane is on by default")
                let style = LayoutStyle().applyingDesignMetrics()
                #expect(style.panePadding == 0, "no inset of a pane inside the main pane's gutter")
                #expect(!style.showsPaneBorder, "no outlined box per pane")
                #expect(style.paneCornerRadius == 0, "no rounded box per pane: the main pane rounds")
                #expect(style.stripGap == 0, "no gap at the column strip's edges or between columns")
                #expect(style.showsDividerLine, "one line between neighboring panes")
                let cell = CGRect(x: 0, y: 0, width: 400, height: 300)
                #expect(PaneChromeGeometry.contentRect(forCell: cell, style: style) == cell)
            }
        }

        /// Dividers are only the default for a cmux.json that says nothing about pane chrome: a pane
        /// corner radius, border color or border width describes a bordered pane, so it keeps borders
        /// (dividers would round flush panes and drop the color and width).
        @Test func aPaneLookSettingWithoutASeparationKeepsBorders() {
            let looks = [PaneChromeOverrides(cornerRadius: 4), PaneChromeOverrides(borderColor: ThemeRGB(hex: 0x336699)),
                         PaneChromeOverrides(borderWidth: 2)]
            for look in looks {
                #expect(PaneSeparation.resolve(look, unset: .dividers) == .borders, "\(look)")
            }
            #expect(PaneSeparation.resolve(PaneChromeOverrides(), unset: .dividers) == .dividers)
        }

        /// A column gap the style carries is honored under every separation: the default inside the
        /// main pane is no gap, but an `appearance.metrics.columnGap` the user set still applies.
        @Test func aColumnGapIsHonoredUnderDividers() {
            for separation in [PaneSeparation.dividers, .none] {
                var style = LayoutStyle()
                style.paneSeparation = separation
                style.panePadding = 0
                style.columnGap = 10
                #expect(style.stripGap == 10, "\(separation)")
            }
        }

        @Test func theGutterRunsBesideTheSidebarToo() throws {
            try onCurvedMainPane {
                let (window, root) = root(sidebarHidden: false)
                defer { window.close() }
                try #require(Metrics.mainPaneCurved && root.sidebar.frame.width > 0)
                let sidebar = root.sidebar.frame, card = root.contentHost.frame
                #expect(Metrics.mainPaneGutter > 0, "the default keeps a gutter on every side")
                #expect(card.minX - sidebar.maxX == Metrics.mainPaneGutter, "the card starts \(card.minX - sidebar.maxX) pt after the sidebar")
                #expect(window.contentView!.bounds.maxX - card.maxX == Metrics.mainPaneGutter, "the gutter at the window edge")
            }
        }

        @Test func withTheSidebarHiddenTheGutterIsAtTheWindowEdge() throws {
            try onCurvedMainPane {
                let (window, root) = root(sidebarHidden: true)
                defer { window.close() }
                try #require(Metrics.mainPaneCurved)
                #expect(Metrics.mainPaneGutter > 0, "the default keeps a gutter at the window edges")
                #expect(root.contentHost.frame.minX == Metrics.mainPaneGutter)
            }
        }

        /// Flush (gutter 0): the pane meets every window edge, and the sidebar when it shows.
        @Test(arguments: [false, true])
        func withNoGutterThePaneMeetsTheWindowEdges(sidebarHidden: Bool) throws {
            try onCurvedMainPane {
                try MainPaneGutterSuites.withGutter(0) {
                    let (window, root) = root(sidebarHidden: sidebarHidden)
                    defer { window.close() }
                    try #require(Metrics.mainPaneCurved)
                    let card = root.contentHost.frame, bounds = window.contentView!.bounds
                    #expect(card.maxX == bounds.maxX && card.maxY == bounds.maxY && card.minY == bounds.minY,
                            "no gutter at the window edges")
                    if sidebarHidden { #expect(card.minX == bounds.minX) } else { #expect(card.minX == root.sidebar.frame.maxX) }
                }
            }
        }
    }
}

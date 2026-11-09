#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// ZOOM VARIANTS 10 (fork only, never merged): a zoom covers a terminal pane by paint only (ZOOM VARIANTS 9): its host
/// stays unhidden at opacity 0. A page (a browser or internal page) shows its Chromium window when AppKit tells it it
/// shows: in a window with no hidden ancestor (`CEFContainerView`, `PageWebView`). A tab switch to a page inside the
/// covered pane unhid the page under an unhidden host, so the page's window showed over the zoomed pane.
/// The rule: content that does not stop on parking never shows inside a pane covered by paint; the cover becomes a hide
/// before it shows, and the unzoom shows the page with its pane.
@MainActor
@Suite(.closesItsWindows)
struct FilmZoomCoverByPaintPageTests {
    /// A terminal surface stand-in: stops on parking (``ParkingObserver``).
    final class Terminal: NSView, ParkingObserver {
        func parkingDidChange() {}
    }

    /// A page stand-in: its window shows by the pages' rule (in a window, no hidden ancestor), checked on each AppKit
    /// visibility hook, as `CEFContainerView` and `PageWebView` do.
    final class Page: NSView {
        private(set) var windowShows = 0
        private(set) var showsWindow = false
        private func sync() {
            let shown = window != nil && !isHiddenOrHasHiddenAncestor
            if shown, !showsWindow { windowShows += 1 }
            showsWindow = shown
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); sync() }
        override func viewDidHide() { super.viewDidHide(); sync() }
        override func viewDidUnhide() { super.viewDidUnhide(); sync() }
    }

    /// Each pane is the app's `PaneContentView` with two tabs: a terminal shown, a page parked hidden behind it.
    final class Panes: LayoutPaneContentProvider {
        var panes: [PaneID: PaneContentView] = [:]
        var pages: [PaneID: (view: InternalPageView, probe: Page)] = [:]
        func makeContentView(for pane: PaneID) -> NSView {
            let view = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("term"), title: "Terminal"),
                                                                         TabItem(id: TabID("page"), title: "Page")]),
                                       reveal: LaunchReveal(deadline: .zero))
            let probe = Page()
            let page = InternalPageView(key: "local-page:markdown:\(pane.rawValue)", page: InternalPageID(rawValue: "markdown"), content: probe)
            view.show(page)
            view.show(Terminal())
            panes[pane] = view
            pages[pane] = (page, probe)
            return view
        }
    }

    @Test(arguments: ["zoom_variant Z4 K6", "zoom_variant Z4 K12"])
    func aTabSwitchToAPageInACoveredPaneShowsNoPageWindow(_ variant: String) throws {
        let film = DesignSettings.shared.filmZoom
        defer { DesignSettings.shared.filmZoom = film }
        _ = FilmZoomVariant.select(variant)
        let provider = Panes()
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(ZoomKeepsCoveredPanesTests.four))],
                                activeScreenID: "s", focusedPane: "p1")
        let root = LayoutRootView(model: model, contentProvider: provider)
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        func land() {
            var frames = 0
            while root.advanceFrame(1.0 / 120), frames < 600 { frames += 1 }
        }
        land()
        let screen = try #require(root.screenViews["s"])
        let pane: PaneID = "p2"
        let host = try #require(root.context.hosts[pane])
        let content = try #require(provider.panes[pane])
        let page = try #require(provider.pages[pane])
        try #require(!page.probe.showsWindow && page.view.isHidden, "the page tab does not start parked behind the terminal")

        // Zoom p1, the film to its end: p2 (a terminal shows) is covered by paint.
        model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf("p1")), zoomed: true)])
        root.syncWithModel()
        _ = root.advanceFrame(1.0 / 120)
        screen.stopFilmFade(retiring: true)
        screen.filmMotionEnded(screen.frameInput.filmZoomGeneration)
        land()
        try #require(root.context.hosts[pane] == nil && host.isCoveredByPaint, "p2 is not covered by paint by the zoom")
        let shownBefore = page.probe.windowShows

        // A tab switch inside the covered pane (a script or `cmux` selects its page tab).
        content.show(page.view)
        #expect(!page.view.isHidden, "the switch did not show the page tab in its pane")
        #expect(page.probe.windowShows == shownBefore && !page.probe.showsWindow,
                "the page's window shows over the zoomed pane: its covered pane is unhidden (opacity 0 hides no child window)")
        #expect(page.probe.isHiddenOrHasHiddenAncestor || page.probe.window == nil, "the page shows inside a covered pane")
        land()
        #expect(!page.probe.showsWindow, "the page's window shows over the zoomed pane after the switch's frames")

        // The unzoom shows the pane and its page.
        model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(ZoomKeepsCoveredPanesTests.four))])
        root.syncWithModel()
        land()
        #expect(root.context.hosts[pane] === host, "p2 came back with a new host")
        #expect(!host.isHidden && !host.isCoveredByPaint && host.layer?.opacity == 1, "p2 does not show after the unzoom")
        #expect(!host.chrome.isHidden && host.chrome.layer?.opacity == 1, "p2's ring does not show after the unzoom")
        #expect(page.probe.showsWindow, "the page's window does not show after the unzoom")
    }
}
#endif

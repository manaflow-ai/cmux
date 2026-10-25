import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import Testing

/// A page's fullscreen (a video's full screen button) in the window's only pane takes the whole
/// window, as in Chrome: the sidebar, title row, tab strip and the main pane's gutter step aside, and
/// the window enters macOS full screen. It stayed inside the pane, with the sidebar and tab strip
/// beside it (2026-10-25). With another pane on screen it stays in its pane, as before.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct PageFullscreenWholeScreenTests {
    typealias Fixture = SidebarMultiViewWindowTests.Fixture

    /// A mock page whose chrome sits in the shown workspace's pane `index`.
    private func page(in fixture: Fixture, pane index: Int = 0) throws -> (MockBrowserTab, PaneController) {
        let content = try #require(fixture.controller.content)
        let pane = try #require(content.panes.values.filter(\.isVisible).sorted { $0.paneKey < $1.paneKey }.dropFirst(index).first)
        let tab = MockBrowserEngine(kind: .webkit).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/watch")))
        let entry = fixture.services.cache.install(tab, for: "page-\(UUID().uuidString.prefix(6))")
        entry.chrome.frame = pane.view.bounds
        pane.view.addSubview(entry.chrome)
        fixture.frame()
        return (tab, pane)
    }

    @Test func aLonePanesPageTakesTheWholeWindow() async throws {
        let fixture = try await Fixture(keys: ["k0", "k1"])
        defer { fixture.close() }
        // A real full screen transition would outlast the test; the decision to enter is what counts.
        fixture.controller.window?.collectionBehavior = [.fullScreenNone]
        let root = fixture.controller.root
        let inset = root.contentHost.frame
        let (tab, pane) = try page(in: fixture)
        #expect(inset != root.bounds, "the main pane starts inset by its gutter")

        tab.simulate(.contentFullscreenChanged(true))
        fixture.frame()
        // DIAG
        let content = try #require(fixture.controller.content)
        let chrome = try #require(pane.view.subviews.first { $0 is BrowserChromeView } as? BrowserChromeView)
        Issue.record("diag: state=\(tab.state.isContentFullscreen) delegateIsController=\(chrome.window?.delegate is WindowController) hasCallback=\(chrome.onContentFullscreenChange != nil) visiblePanes=\(content.panes.values.filter(\.isVisible).count) allPanes=\(content.panes.count) parkedDrawing=\(fixture.controller.parked.values.filter { !$0.drawsNothing }.count) chromeHidden=\(chrome.isHiddenOrHasHiddenAncestor) inPane=\(chrome.isDescendant(of: pane.view)) windowSame=\(chrome.window === fixture.controller.window)")
        #expect(fixture.controller.pagePresentation?.entersWindowFullScreen == true, "the window enters full screen for the page")
        #expect(root.contentHost.frame == root.bounds, "the page fills the window, edge to edge")
        #expect(root.sidebar.isHiddenOrHasHiddenAncestor, "the sidebar steps aside")
        #expect(pane.view.hidesStrip, "the tab strip steps aside")

        tab.simulate(.contentFullscreenChanged(false))
        fixture.frame()
        #expect(fixture.controller.pagePresentation == nil)
        #expect(root.contentHost.frame == inset, "the main pane is back where it was")
        #expect(!root.sidebar.isHidden, "the sidebar is back")
        #expect(!pane.view.hidesStrip, "the tab strip is back")
    }

    @Test func aPageBesideAnotherPaneStaysInItsPane() async throws {
        let fixture = try await Fixture(keys: ["k0", "k1"])
        defer { fixture.close() }
        fixture.controller.window?.collectionBehavior = [.fullScreenNone]
        fixture.controller.showWorkspace(requested: "k1") // two panes side by side
        fixture.frame()
        let root = fixture.controller.root
        let inset = root.contentHost.frame
        let (tab, pane) = try page(in: fixture)

        tab.simulate(.contentFullscreenChanged(true))
        fixture.frame()
        #expect(fixture.controller.pagePresentation == nil, "the window keeps its chrome")
        #expect(root.contentHost.frame == inset)
        #expect(!root.sidebar.isHidden)
        #expect(!pane.view.hidesStrip)
    }

    @Test func switchingAwayEndsThePagesFullscreen() async throws {
        let fixture = try await Fixture(keys: ["k0", "k1"])
        defer { fixture.close() }
        fixture.controller.window?.collectionBehavior = [.fullScreenNone]
        let root = fixture.controller.root
        let inset = root.contentHost.frame
        let (tab, _) = try page(in: fixture)
        tab.simulate(.contentFullscreenChanged(true))
        fixture.frame()
        try #require(fixture.controller.pagePresentation != nil)

        fixture.controller.showWorkspace(requested: "k1")
        fixture.frame()
        #expect(fixture.controller.pagePresentation == nil, "the other workspace shows with the window's chrome")
        #expect(!tab.state.isContentFullscreen, "the page left on screen elsewhere leaves fullscreen, as in Chrome")
        #expect(root.contentHost.frame == inset)
    }

    /// A top page (Settings, a create page) parks the workspace before it hides it: the page that
    /// had the screen leaves fullscreen then too, not only its window's chrome coming back.
    @Test func aTopPageEndsThePagesFullscreen() async throws {
        let fixture = try await Fixture(keys: ["k0", "k1"])
        defer { fixture.close() }
        fixture.controller.window?.collectionBehavior = [.fullScreenNone]
        let (tab, _) = try page(in: fixture)
        tab.simulate(.contentFullscreenChanged(true))
        fixture.frame()
        try #require(fixture.controller.pagePresentation != nil)

        fixture.controller.parkContentForPage()
        fixture.frame()
        #expect(fixture.controller.pagePresentation == nil)
        #expect(!tab.state.isContentFullscreen, "the page under the top page leaves fullscreen")
        #expect(!fixture.controller.root.presentsPage)
    }
}

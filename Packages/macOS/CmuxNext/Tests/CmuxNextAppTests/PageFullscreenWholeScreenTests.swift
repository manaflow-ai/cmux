import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// A page's fullscreen (a video's full screen button) in the window's only pane takes the whole
/// window, as in Chrome: the sidebar, title row, tab strip and the main pane's gutter step aside, and
/// the window enters macOS full screen. It stayed inside the pane, with the sidebar and tab strip
/// beside it (2026-10-25), and with another pane on screen it still did (2026-11-09).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .closesItsWindows)
struct PageFullscreenWholeScreenTests {
    typealias Fixture = SidebarMultiViewWindowTests.Fixture

    /// A mock page whose chrome sits in the shown workspace's pane `index`.
    private func page(in fixture: Fixture, pane index: Int = 0) throws -> (MockBrowserTab, PaneController) {
        let content = try #require(fixture.controller.content)
        let pane = try #require(content.panes.values.filter(\.isVisible).sorted { $0.paneKey < $1.paneKey }.dropFirst(index).first)
        let tab = MockBrowserEngine(kind: .webkit).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/watch")))
        let entry = fixture.services.cache.install(tab, for: "page-\(UUID().uuidString.prefix(6))")
        let chrome = pane.view.browserChrome.bind(entry.tab, state: entry.state)
        chrome.frame = pane.view.bounds
        pane.view.addSubview(chrome)
        fixture.frame()
        return (tab, pane)
    }

    /// Frames until `condition` holds: the chrome hears its page on a later main-actor turn.
    private func until(_ fixture: Fixture, _ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            fixture.frame()
        }
        try #require(condition(), "\(what) never happened")
    }

    /// The page goes fullscreen and the chrome has heard it.
    private func enter(_ tab: MockBrowserTab, _ fixture: Fixture) async throws {
        tab.simulate(.contentFullscreenChanged(true))
        try await settle(fixture)
    }

    /// A few turns and frames, so every main-actor hop after a change has run.
    private func settle(_ fixture: Fixture) async throws {
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(20))
            fixture.frame()
        }
    }

    @Test func aLonePanesPageTakesTheWholeWindow() async throws {
        // Setup can throw after opening its window; register the owned-window cleanup first.
        defer { AppHarnessWindows.closeThoseThisTestOpened() }
        let fixture = try await Fixture(keys: ["k0", "k1"])
        defer { fixture.close() }
        // A real full screen transition would outlast the test; the decision to enter is what counts.
        fixture.controller.window?.collectionBehavior = [.fullScreenNone]
        let root = fixture.controller.root
        let inset = root.contentHost.frame
        let (tab, pane) = try page(in: fixture)
        #expect(inset != root.bounds, "the main pane starts inset by its gutter")

        tab.simulate(.contentFullscreenChanged(true))
        try await until(fixture, "the page takes the window") { fixture.controller.pagePresentation != nil }
        #expect(fixture.controller.pagePresentation?.entersWindowFullScreen == true, "the window enters full screen for the page")
        #expect(root.contentHost.frame == root.bounds, "the page fills the window, edge to edge")
        #expect(root.sidebar.isHiddenOrHasHiddenAncestor, "the sidebar steps aside")
        #expect(pane.view.hidesStrip, "the tab strip steps aside")

        tab.simulate(.contentFullscreenChanged(false))
        try await until(fixture, "the window takes its chrome back") { fixture.controller.pagePresentation == nil }
        #expect(root.contentHost.frame == inset, "the main pane is back where it was")
        #expect(!root.sidebar.isHidden, "the sidebar is back")
        #expect(!pane.view.hidesStrip, "the tab strip is back")
    }

    /// A video beside a chat (two panes) took only its own pane: fullscreen looked broken
    /// (user, 2026-11-09). Chrome gives a page's fullscreen the whole screen whatever the window
    /// shows; so does cmux now, hiding the pane beside it for the while and putting the split back.
    @Test func aPageBesideAnotherPaneTakesTheWholeWindow() async throws {
        // Setup can throw after opening its window; register the owned-window cleanup first.
        defer { AppHarnessWindows.closeThoseThisTestOpened() }
        let fixture = try await Fixture(keys: ["k0", "k1"])
        defer { fixture.close() }
        fixture.controller.window?.collectionBehavior = [.fullScreenNone]
        fixture.controller.showWorkspace(requested: "k1") // two panes side by side
        fixture.frame()
        let root = fixture.controller.root
        let inset = root.contentHost.frame
        let content = try #require(fixture.controller.content)
        let (tab, pane) = try page(in: fixture)
        let beside = try #require(content.panes.values.first { $0.isVisible && $0 !== pane }, "a second pane is on screen")
        // The layout model, not frames: a split springs to its sizes over several frames.
        let layoutBefore = content.layoutModel.screens
        let zoomBefore = content.workspace.screens.map(\.zoomedPane)

        try await enter(tab, fixture)
        try await until(fixture, "the page takes the window") { fixture.controller.pagePresentation != nil }
        #expect(fixture.controller.pagePresentation?.entersWindowFullScreen == true, "the window enters full screen for the page")
        #expect(root.contentHost.frame == root.bounds, "the page fills the window, edge to edge")
        #expect(root.sidebar.isHiddenOrHasHiddenAncestor, "the sidebar steps aside")
        #expect(pane.view.hidesStrip, "the tab strip steps aside")
        #expect(content.panes[beside.layoutPaneID]?.isVisible != true, "the pane beside the page steps aside")
        let presented = try #require(content.layoutModel.screens.first { $0.layout.panes.contains(pane.layoutPaneID) })
        #expect(presented.layout.panes == [pane.layoutPaneID] && presented.zoomed, "the page's pane alone fills its screen")
        #expect(content.workspace.screens.map(\.zoomedPane) == zoomBefore, "nothing of it reaches the daemon's tree")

        tab.simulate(.contentFullscreenChanged(false))
        try await until(fixture, "the window takes its chrome back") { fixture.controller.pagePresentation == nil }
        try await settle(fixture)
        #expect(root.contentHost.frame == inset, "the main pane is back where it was")
        #expect(!root.sidebar.isHidden, "the sidebar is back")
        #expect(!pane.view.hidesStrip, "the tab strip is back")
        let besideAfter = try #require(content.panes[beside.layoutPaneID], "the pane beside is still there")
        #expect(besideAfter.isVisible, "the pane beside is back")
        #expect(content.layoutModel.screens == layoutBefore, "the split is exactly as it was")
    }

    @Test func switchingAwayEndsThePagesFullscreen() async throws {
        // Setup can throw after opening its window; register the owned-window cleanup first.
        defer { AppHarnessWindows.closeThoseThisTestOpened() }
        let fixture = try await Fixture(keys: ["k0", "k1"])
        defer { fixture.close() }
        fixture.controller.window?.collectionBehavior = [.fullScreenNone]
        let root = fixture.controller.root
        let inset = root.contentHost.frame
        let (tab, _) = try page(in: fixture)
        tab.simulate(.contentFullscreenChanged(true))
        try await until(fixture, "the page takes the window") { fixture.controller.pagePresentation != nil }

        fixture.controller.showWorkspace(requested: "k1")
        fixture.frame()
        #expect(fixture.controller.pagePresentation == nil, "the other workspace shows with the window's chrome")
        #expect(!tab.state.isContentFullscreen, "the page left on screen elsewhere leaves fullscreen, as in Chrome")
        #expect(root.contentHost.frame == inset)
    }

    /// A top page (Settings, a create page) parks the workspace before it hides it: the page that
    /// had the screen leaves fullscreen then too, not only its window's chrome coming back.
    @Test func aTopPageEndsThePagesFullscreen() async throws {
        // Setup can throw after opening its window; register the owned-window cleanup first.
        defer { AppHarnessWindows.closeThoseThisTestOpened() }
        let fixture = try await Fixture(keys: ["k0", "k1"])
        defer { fixture.close() }
        fixture.controller.window?.collectionBehavior = [.fullScreenNone]
        let (tab, _) = try page(in: fixture)
        tab.simulate(.contentFullscreenChanged(true))
        try await until(fixture, "the page takes the window") { fixture.controller.pagePresentation != nil }

        fixture.controller.parkContentForPage()
        fixture.frame()
        #expect(fixture.controller.pagePresentation == nil)
        #expect(!tab.state.isContentFullscreen, "the page under the top page leaves fullscreen")
        #expect(!fixture.controller.root.presentsPage)
    }
}

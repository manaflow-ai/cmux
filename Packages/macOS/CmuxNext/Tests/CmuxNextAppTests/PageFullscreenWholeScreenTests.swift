import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Testing

/// A page's fullscreen (a video's full screen button) in the window's only pane takes the whole
/// window, as in Chrome: the sidebar, title row, tab strip and the main pane's gutter step aside, and
/// the window enters macOS full screen. It stayed inside the pane, with the sidebar and tab strip
/// beside it (2026-10-25). With another pane on screen it stays in its pane, as before.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .closesItsWindows)
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
        let fixture = try await Fixture(keys: ["k0", "k1"])
        defer {
            fixture.close()
            // The page's Page Info and Extensions bubbles live as long as its chrome, which the app keeps.
            AppHarnessWindows.closeThoseThisTestOpened()
        }
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

    @Test func aPageBesideAnotherPaneStaysInItsPane() async throws {
        let fixture = try await Fixture(keys: ["k0", "k1"])
        defer {
            fixture.close()
            // The page's Page Info and Extensions bubbles live as long as its chrome, which the app keeps.
            AppHarnessWindows.closeThoseThisTestOpened()
        }
        fixture.controller.window?.collectionBehavior = [.fullScreenNone]
        fixture.controller.showWorkspace(requested: "k1") // two panes side by side
        fixture.frame()
        let root = fixture.controller.root
        let inset = root.contentHost.frame
        let (tab, pane) = try page(in: fixture)

        try await enter(tab, fixture)
        #expect(tab.state.isContentFullscreen)
        #expect(fixture.controller.pagePresentation == nil, "the window keeps its chrome")
        #expect(root.contentHost.frame == inset)
        #expect(!root.sidebar.isHidden)
        #expect(!pane.view.hidesStrip)
    }

    @Test func switchingAwayEndsThePagesFullscreen() async throws {
        let fixture = try await Fixture(keys: ["k0", "k1"])
        defer {
            fixture.close()
            // The page's Page Info and Extensions bubbles live as long as its chrome, which the app keeps.
            AppHarnessWindows.closeThoseThisTestOpened()
        }
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
        let fixture = try await Fixture(keys: ["k0", "k1"])
        defer {
            fixture.close()
            // The page's Page Info and Extensions bubbles live as long as its chrome, which the app keeps.
            AppHarnessWindows.closeThoseThisTestOpened()
        }
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

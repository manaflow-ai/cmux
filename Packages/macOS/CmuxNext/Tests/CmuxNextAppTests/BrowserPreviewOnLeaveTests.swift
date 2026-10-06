import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CoreGraphics
import Testing
@testable import CmuxNextApp

/// R131: the engine page capture (WKWebView takeSnapshot, CEF
/// Page.captureScreenshot) runs on the main thread, so a hover must never
/// start one. A browser tab's thumbnail is taken when the tab leaves the
/// screen, and the hover card reads that cached image.
@MainActor @Suite struct BrowserPreviewOnLeaveTests {
    final class Pane: SurfacePresenter {
        func surfaceWasDisplaced(_ key: String) {}
    }

    /// Waits (bounded) for the capture that leaving the screen starts.
    func eventually(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: Self.captureDeadline)
        while !condition(), clock.now < end { try await clock.sleep(for: .milliseconds(10)) } // test-only wait
    }

    /// The shared 30 s test deadline: these tests check when a capture runs,
    /// not its deadline. Under a loaded `swift test` process the main actor
    /// can wait more than the app's 2 s, and the capture was then dropped.
    static let captureDeadline: Duration = .seconds(30)

    func makeCache() -> TabContentCache {
        let cache = TabContentCache(daemon: DaemonService())
        cache.pageCaptureDeadline = Self.captureDeadline
        return cache
    }

    @Test func aTabSwitchAwayCapturesOnceAndTheHoverCapturesNothing() async throws {
        let cache = makeCache()
        let page = MockBrowserEngine(kind: .webkit).makeMockTab(BrowserTabConfiguration())
        cache.install(page, for: "tab")
        let pane = Pane()
        cache.present("tab", by: pane, presence: .visible)
        #expect(page.snapshotCount == 0, "a shown tab is not captured")

        cache.withdraw("tab", by: pane)
        try await eventually { cache.pageThumbnails.image(for: "tab") != nil }
        #expect(page.snapshotCount == 1, "the switch away captures once")
        #expect(cache.pageThumbnails.image(for: "tab") != nil, "the capture is cached for the tab")

        let image = await cache.previewImage(for: "tab", maxPixelSize: CGSize(width: 480, height: 270))
        #expect(image != nil, "the hover card gets the image taken on leave")
        #expect(page.snapshotCount == 1, "the hover starts no capture")
    }

    @Test func aNeverCapturedTabShowsThePlaceholder() async {
        let cache = TabContentCache(daemon: DaemonService())
        let page = MockBrowserEngine(kind: .webkit).makeMockTab(BrowserTabConfiguration())
        cache.install(page, for: "tab")
        let image = await cache.previewImage(for: "tab", maxPixelSize: CGSize(width: 480, height: 270))
        #expect(image == nil, "no cached capture: the card shows its placeholder")
        #expect(page.snapshotCount == 0, "the hover starts no capture")
    }

    /// A window that resigns key captures the page it shows (a hover from
    /// another window then has a thumbnail), once per deactivation, and
    /// never a page that is not on screen.
    @Test func aWindowResigningKeyCapturesItsShownPageOnce() async throws {
        let cache = makeCache()
        let shown = MockBrowserEngine(kind: .webkit).makeMockTab(BrowserTabConfiguration())
        let hidden = MockBrowserEngine(kind: .webkit).makeMockTab(BrowserTabConfiguration())
        cache.install(shown, for: "shown")
        cache.install(hidden, for: "hidden")
        let pane = Pane(), other = Pane()
        cache.present("shown", by: pane, presence: .visible)
        cache.present("hidden", by: other, presence: .hidden)

        cache.windowDidResignKey(presenters: [pane, other])
        try await eventually { cache.pageThumbnails.image(for: "shown") != nil }
        #expect(shown.snapshotCount == 1, "one capture per deactivation")
        #expect(cache.pageThumbnails.image(for: "shown") != nil)
        #expect(hidden.snapshotCount == 0, "a page not on screen is not captured")

        cache.windowDidResignKey(presenters: [pane, other])
        try await eventually { shown.snapshotCount == 2 }
        #expect(shown.snapshotCount == 2, "the next deactivation captures again")
        _ = await cache.previewImage(for: "shown", maxPixelSize: CGSize(width: 480, height: 270))
        #expect(shown.snapshotCount == 2, "the hover starts no capture")
    }
}

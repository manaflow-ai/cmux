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
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aTabSwitchAwayCapturesOnceAndTheHoverCapturesNothing() async throws {
        let cache = TabContentCache(daemon: DaemonService())
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
}

import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import Foundation
import Testing

/// P0 #1 (2026-10-28): the leave picture of a browser page (R131's hover card thumbnail) was asked for in a task that
/// ran after the conceal had hidden the page, so Chromium copied the surface of a hidden page; such a copy fails and
/// retries, and a page closed or discarded meanwhile crashed Chromium (SIGSEGV in
/// `RenderWidgetHostImpl::OnSnapshotFromSurfaceReceived`, 21 reports of optimized builds). The picture is asked for in
/// the conceal's own turn, while the page still shows, and never of a page the lifecycle has hidden.
@MainActor @Suite(.serialized)
struct PageLeaveCaptureTests {
    @Test func theLeavePictureIsAskedForWhileThePageStillShows() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/")))
        let key = tab.id.rawValue
        _ = services.cache.install(tab, for: key)
        defer { services.cache.browsers[key] = nil }
        try #require(tab.state.phase == .finished)
        let cache = services.cache
        cache.applyLifecycle(cache.lifecycle.send(.show(key)))
        try #require(cache.shownPages.contains(key) && !tab.isContentHidden, "the page never showed")

        cache.applyLifecycle(cache.lifecycle.send(.hide(key)))
        #expect(tab.isContentHidden)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while tab.thumbnailCount == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(tab.thumbnailCount == 1, "the leave took \(tab.thumbnailCount) pictures")
        #expect(tab.hiddenThumbnailCount == 0, "the leave picture was asked for after the page was hidden")
    }
}

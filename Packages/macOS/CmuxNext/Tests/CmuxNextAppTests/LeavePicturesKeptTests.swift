import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import Foundation
import Testing

/// Every page that left the screen keeps its leave picture until it closes (HOT PATH AUDIT browser, AUDIT section 2.7
/// item 3). On fork API 24 Chromium pictures no hidden page, so a hibernated Chromium tab wakes to its LEAVE picture:
/// the one taken while it still showed (`capturePagePreview`). Those pictures were kept decoded in a 16 MB LRU (about
/// 14 pages of 640 x 640 px), so a session that hid more pages lost the oldest ones' pictures before they hibernated
/// (fleet jobs e2fb152d and 05f0ba3c: 14 and 13 of 24 woken tabs had a picture). Chrome keeps each tab's thumbnail
/// compressed, per tab, for the tab's life (ThumbnailImage); so does this cache now.
@MainActor @Suite(.serialized)
struct LeavePicturesKeptTests {
    @Test func everyHiddenPageKeepsItsLeavePicture() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let cache = services.cache
        let engine = MockBrowserEngine()
        var pages: [(key: String, tab: MockBrowserTab)] = []
        defer { for page in pages { cache.browsers[page.key] = nil } }
        for index in 0..<24 {
            let tab = engine.makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://site\(index).example/")))
            tab.snapshotPixelSize = CGSize(width: 640, height: 400)  // a pane's leave picture, at the cache's own size
            let key = tab.id.rawValue
            _ = cache.install(tab, for: key)
            pages.append((key, tab))
            try #require(tab.state.phase == .finished)
            cache.applyLifecycle(cache.lifecycle.send(.show(key)))
            cache.applyLifecycle(cache.lifecycle.send(.hide(key)))
            // The leave picture is scaled and measured off the main thread: wait until this page's is kept.
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !cache.pagePictureIsCurrent(cache.browsers[key]!, key: key), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(cache.pagePictureIsCurrent(cache.browsers[key]!, key: key), "page \(index) kept no leave picture")
        }
        let kept = pages.filter { cache.pagePictureIsCurrent(cache.browsers[$0.key]!, key: $0.key) }.count
        print("LEAVE-PICTURES kept \(kept) of \(pages.count) (cache \(cache.pageThumbnails.totalBytes) bytes)")
        #expect(kept == pages.count, "only \(kept) of \(pages.count) hidden pages kept their leave picture")
    }
}

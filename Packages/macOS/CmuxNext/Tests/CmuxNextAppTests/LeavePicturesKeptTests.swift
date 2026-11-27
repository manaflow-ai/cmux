import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
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

    /// A drag ghost, a hover card with an old picture and the screen bar card wait for an on-demand capture
    /// (`previewImage`): it returns the fresh capture with no encode before it. Every encode is held here until the call
    /// returns (a call that waits for one returns only after the 10 s release); the compression into the store runs
    /// after, off the waiting path, and replaces the decoded copy for later reads.
    @Test func anOnDemandCaptureReturnsBeforeAnyEncode() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let cache = services.cache
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://demand.example/")))
        tab.snapshotPixelSize = CGSize(width: 640, height: 400)
        let key = tab.id.rawValue
        _ = cache.install(tab, for: key)
        defer { cache.browsers[key] = nil }
        try #require(tab.state.phase == .finished)
        cache.shownPages.insert(key)  // a page on screen with no current picture: its card asks for a capture
        let hold = EncodeHold()
        cache.pageThumbnails.encode = { image in
            await hold.enter()
            let kept = PreviewImageCache.compressed(image, quality: 0.8)
            await hold.finish()
            return kept
        }

        let call = OnDemandCall()
        let task = Task { @MainActor in
            let image = await cache.previewImage(for: key, maxPixelSize: CGSize(width: 320, height: 200))
            call.encodesDone = await hold.done
            call.image = image
            call.returned = true
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !call.returned, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        await hold.release()
        await task.value
        #expect(call.image != nil, "the on-demand capture gave no picture")
        #expect(call.encodesDone == 0, "the on-demand capture waited for \(call.encodesDone) encodes")

        // The compressed copy follows, off the waiting path, and replaces the decoded one in the store.
        let stored = ContinuousClock.now.advanced(by: .seconds(10))
        while cache.pageThumbnails.totalBytes >= 640 * 400 * 4, ContinuousClock.now < stored {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(cache.pageThumbnails.totalBytes < 640 * 400 * 4, "the stored picture was never compressed (\(cache.pageThumbnails.totalBytes) bytes)")
    }
}

/// Holds every encode until released, and counts the encodes done.
private actor EncodeHold {
    private(set) var done = 0
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !released { await withCheckedContinuation { waiting.append($0) } }
    }

    func finish() { done += 1 }

    func release() {
        released = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

/// What the on-demand call saw when it returned.
@MainActor private final class OnDemandCall {
    var image: CGImage?
    var returned = false
    var encodesDone = -1
}

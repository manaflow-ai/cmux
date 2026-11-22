import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBridge
@testable import CmuxNextBrowser
import CmuxNextTabs
import CmuxNextWakeups
import Foundation
import Testing

/// Leo 2026-11-22: "if the previews dont show up, what's the point?" After a relaunch, hovering a browser tab not
/// shown since showed an empty card: every hover picture lived in memory, and Chromium pictures no hidden page. The
/// card now shows the tab's last picture from the run before (`BrowserPageFrames`, the store a restored tab's first
/// show draws from), before and after that first show takes it.
@MainActor @Suite(.serialized) struct RestoredTabHoverPreviewTests {
    private static let size = CGSize(width: 320, height: 200)

    @Test func aBrowserTabNotShownSinceTheRelaunchShowsItsLastPicture() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appending(path: "restored-hover-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = "tab_restored_hover"
        let data = try #require(BrowserPageFrames.encoded(try NewTabHoverPreviewTests.striped()))
        BrowserPageFrames.write(data, key: key, scale: 2, to: folder, capacity: 1 << 20)

        // The next launch: the folder is read, the tab has no page yet.
        let services = AppServices(environment: AppEnvironment.current([:]))
        let frames = BrowserPageFrames(directory: folder)
        await frames.prefetch(on: BackgroundWork()).value
        services.cache.pageFrames = frames
        #expect(services.cache.browsers[key] == nil)

        let previews = TabPreviewSource(cache: services.cache, pages: services.pages)
        #expect(await previews.previewImage(for: TabID(key), maxPixelSize: Self.size) != nil,
                "a tab not shown since the relaunch had no hover picture although its last picture was on disk")
        #expect(await previews.previewImage(for: TabID(key), maxPixelSize: Self.size) != nil, "a hover took the picture")
        #expect(frames.take(key) != nil, "a hover took the picture the tab's first show draws")

        // Its first show took the picture (the stand-in): the card keeps showing it.
        let picture = try NewTabHoverPreviewTests.striped()
        let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        defer { page.close() }
        services.cache.install(page, for: key)
        defer { services.cache.browsers[key] = nil }
        services.cache.keepRestoredPreview(picture, for: key)
        for _ in 0..<200 where services.cache.pageThumbnails.image(for: key) == nil { await Task.yield() }
        #expect(services.cache.pageThumbnails.image(for: key) != nil, "the first show's picture was not kept for the card")
        #expect(await services.cache.previewImage(for: key, maxPixelSize: Self.size) != nil,
                "after its first show took the last picture, the tab's hover card had none")
    }
}

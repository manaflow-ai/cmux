import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextMobileHost
import CmuxNextWakeups
import Foundation
import Testing

/// Leo 2026-11-22: "this is so fucked. constant rerenders on every fucking page still." A restored Chromium tab first
/// shown after a relaunch had no page while Chromium made it (`browser(for:)` returned nil): the pane showed nothing,
/// the omnibar "Search or type URL", then a cold load. It now shows its last picture from the run before
/// (`BrowserPageFrames`) and its recorded address in the frame of the switch, and the page goes under that picture.
@MainActor @Suite(.serialized) struct RestoredPageLastFrameTests {
    private static let address = "https://github.com/manaflow-ai/cmux/pull/1"

    private func cache() -> TabContentCache {
        let cache = TabContentCache(daemon: DaemonService(), cef: CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks()), fileInput: NoFileInput())
        cache.browserTabs.cefUnavailable = { nil }
        return cache
    }

    private func restoredTab(_ surface: UInt64, engine: String = "cef") -> TabModel {
        TabModel(TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .browser, url: Self.address, browserRenderer: "frontend", browserEngine: engine))
    }

    private static func picture() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 120, height: 90, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 90))
        return try #require(context.makeImage())
    }

    /// A store whose last run kept `key`'s picture.
    private func frames(with key: String) async throws -> (BrowserPageFrames, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "restored-page-frames-\(UUID().uuidString)", directoryHint: .isDirectory)
        BrowserPageFrames.write(try #require(BrowserPageFrames.encoded(try Self.picture())), key: key, scale: 2, to: folder, capacity: 1 << 20)
        let frames = BrowserPageFrames(directory: folder)
        await frames.prefetch(on: BackgroundWork()).value
        return (frames, folder)
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func aRestoredTabShowsItsPictureAndAddressWhileItsPageIsMade() async throws {
        let cache = cache()
        let tab = restoredTab(81)
        let (frames, folder) = try await frames(with: tab.id)
        defer { cache.release(tab.id); try? FileManager.default.removeItem(at: folder) }
        cache.pageFrames = frames
        var release: CheckedContinuation<Void, Never>?
        var made: MockBrowserTab?
        cache.makeCEFTab = { configuration in
            await withCheckedContinuation { release = $0 }
            let page = MockBrowserEngine(kind: .cef, completesNavigationsImmediately: false).makeMockTab(configuration)
            made = page
            return page
        }
        let entry = try #require(cache.browser(for: tab), "the switch has a page to show in its own frame")
        let placeholder = try #require(entry.tab as? DeferredBrowserTab)
        #expect(placeholder.picture != nil, "the last run's picture")
        #expect(placeholder.contentView is BrowserPictureView)
        #expect(placeholder.state.url?.absoluteString == Self.address, "the omnibar keeps the recorded address, never blank")
        #expect(cache.isRestoring(tab.id))
        #expect(!frames.hasPicture(tab.id), "handed out once")

        try await until { release != nil }
        release?.resume()
        try await until { !cache.isRestoring(tab.id) }
        let page = try #require(made)
        #expect(cache.existingBrowser(tab.id)?.tab === page, "the page replaced the stand-in")
    }

    @Test func aLoadTheUserStartsInTheGapRunsOnThePage() async throws {
        let cache = cache()
        let tab = restoredTab(82)
        defer { cache.release(tab.id) }
        var release: CheckedContinuation<Void, Never>?
        var made: MockBrowserTab?
        cache.makeCEFTab = { configuration in
            await withCheckedContinuation { release = $0 }
            let page = MockBrowserEngine(kind: .cef, completesNavigationsImmediately: false).makeMockTab(configuration)
            made = page
            return page
        }
        let entry = try #require(cache.browser(for: tab))
        #expect((entry.tab as? DeferredBrowserTab)?.picture == nil, "no picture kept: the stand-in still shows the address")
        #expect(entry.tab.state.url?.absoluteString == Self.address)
        let typed = try #require(URL(string: "https://example.com/typed"))
        entry.tab.load(typed)
        try await until { release != nil }
        release?.resume()
        try await until { made != nil && !cache.isRestoring(tab.id) }
        #expect(made?.commands.contains(.load(typed)) == true)
    }

    @Test func automationWaitsForThePageNotTheStandIn() async throws {
        let cache = cache()
        let tab = restoredTab(83)
        defer { cache.release(tab.id) }
        cache.makeCEFTab = { configuration in
            try await Task.sleep(for: .seconds(30))
            return MockBrowserEngine(kind: .cef).makeMockTab(configuration)
        }
        _ = try #require(cache.browser(for: tab))
        #expect(cache.isRestoring(tab.id), "AppBrowserPage treats a restoring tab as one with no page yet")
    }

    @Test func aClosedRestoringTabForgetsItsStandInAndPicture() async throws {
        let cache = cache()
        let tab = restoredTab(84)
        let (frames, folder) = try await frames(with: tab.id)
        defer { try? FileManager.default.removeItem(at: folder) }
        cache.pageFrames = frames
        cache.makeCEFTab = { configuration in
            try await Task.sleep(for: .seconds(30))
            return MockBrowserEngine(kind: .cef).makeMockTab(configuration)
        }
        _ = try #require(cache.browser(for: tab))
        cache.release(tab.id)
        #expect(!cache.isRestoring(tab.id))
        #expect(cache.existingBrowser(tab.id) == nil)
        try await until { BrowserPageFrames.files(in: folder).isEmpty }
    }

    @Test func anIncognitoTabsPageIsNeverKeptOnDisk() throws {
        let cache = cache()
        cache.browserTabs.cefUnavailable = { .notBundled }  // a WebKit page, made now
        let tab = restoredTab(85, engine: "webkit")
        defer { cache.release(tab.id) }
        _ = try #require(cache.browser(for: tab))
        #expect(cache.keepsFrameOnDisk(tab.id), "a normal page is kept")
        cache.browserTabs.isIncognitoTab = { $0 == tab.id }
        #expect(!cache.keepsFrameOnDisk(tab.id), "an incognito page never is")
    }

    @Test func aStandInOrMockPageIsNeverKeptOnDisk() async throws {
        let cache = cache()
        let tab = restoredTab(86)
        defer { cache.release(tab.id) }
        cache.makeCEFTab = { configuration in
            try await Task.sleep(for: .seconds(30))
            return MockBrowserEngine(kind: .cef).makeMockTab(configuration)
        }
        _ = try #require(cache.browser(for: tab))
        #expect(!cache.keepsFrameOnDisk(tab.id), "the stand-in's picture is not the page's")
    }

    @Test func aRestoredWebKitTabIsCoveredByItsPicture() async throws {
        let cache = cache()
        cache.browserTabs.cefUnavailable = { .notBundled }
        let tab = restoredTab(87, engine: "webkit")
        let (frames, folder) = try await frames(with: tab.id)
        defer { cache.release(tab.id); try? FileManager.default.removeItem(at: folder) }
        cache.pageFrames = frames
        let page = try #require(cache.browser(for: tab)?.tab as? WebKitTab)
        #expect(page.standIn != nil, "its last picture covers the page until it paints")
        #expect(!frames.hasPicture(tab.id))
    }

    /// Leo 2026-11-24: "there are too many empty previews in the safari grid thing we ought to be able to simply
    /// capture them before they get hibernated maybe". After a relaunch a browser tab not shown since has no page
    /// (Chromium makes it on the first show), and the phones' pictures were only of tabs with a page: its card stayed
    /// blank though its last picture was on disk. That picture now goes to the phones, once the read of the disk ends
    /// and the tab's surface is known.
    @Test func aTabNotShownSinceTheRelaunchSendsItsLastPictureToThePhones() async throws {
        let cache = cache()
        let tab = restoredTab(42)
        let (frames, folder) = try await frames(with: tab.id)
        let phoneFolder = FileManager.default.temporaryDirectory.appending(path: "restored-phone-pictures-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: phoneFolder) }
        cache.pageFrames = frames
        var known = false // the tab list loads after the pictures are held
        cache.findTab = { known && $0 == tab.id ? tab : nil }
        let iphone = IPhoneHostService(loginKeychain: LoginKeychain())
        cache.phonePictures = PhoneTabPictures(iphone: iphone, folder: phoneFolder, surface: { [weak cache] in cache?.phoneSurface($0) },
                                               encode: { _, _, _ in (Data([0xFF, 0xD8, 0xFF, 3]), 8, 5) }, wanted: { true })
        let sent = { ((try? FileManager.default.contentsOfDirectory(atPath: phoneFolder.path)) ?? []).contains { $0.hasPrefix("42-thumb-") } }
        #expect(cache.existingBrowser(tab.id) == nil, "the tab has no page")
        try await Task.sleep(for: .milliseconds(200))
        #expect(!sent(), "no surface known yet")
        known = true
        cache.phonePictures?.heldChanged()
        try await until { sent() }
        #expect(frames.hasPicture(tab.id), "the restored tab's first show still gets its picture")
        withExtendedLifetime(iphone) {}
    }

    /// A picture saved this run (a hibernated page's) is held in memory as written, not as bytes: the phones' card
    /// reads it from disk.
    @Test func aPictureSavedThisRunIsReadBackFromDisk() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "saved-page-frames-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let frames = BrowserPageFrames(directory: folder)
        await frames.prefetch(on: BackgroundWork()).value
        frames.save(try Self.picture(), for: "a")
        #expect(frames.keys.contains("a"))
        let deadline = ContinuousClock.now + .seconds(10)
        var picture: CGImage?
        while picture == nil, ContinuousClock.now < deadline {
            picture = await frames.lastPicture("a")
            if picture == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(picture?.width == 120)
        frames.remove("a")
        #expect(!frames.keys.contains("a"))
    }
}

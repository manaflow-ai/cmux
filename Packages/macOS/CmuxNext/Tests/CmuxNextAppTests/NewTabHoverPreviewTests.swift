import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBridge
@testable import CmuxNextBrowser
@testable import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// Leo 2026-10-13: hovering a browser tab on the New Tab page showed a card with
/// `chrome://newtab/` under the title and an all-black thumbnail (the New Tab page is a flat page
/// in the theme background). A New Tab or blank page has no thumbnail and no address line; a
/// flat capture (a page that had not painted, a terminal with only its prompt) is no thumbnail
/// either.
@MainActor @Suite(.serialized) struct NewTabHoverPreviewTests {
    @Test func aNewTabPageShowsNoAddressLine() {
        for url in ["chrome://newtab/", "about:blank"] {
            let tab = TabModel(TabSnapshot(surface: 4, kind: .browser, title: url, url: url))
            let item = TabItemMapping.shared.item(tab, fallbackTitle: "New Tab")
            #expect(item.title == "New Tab")
            #expect(item.subtitle == nil, "the card named \(url) under the title")
        }
        let page = TabModel(TabSnapshot(surface: 5, kind: .browser, title: "Example", url: "https://example.com/"))
        #expect(TabItemMapping.shared.item(page, fallbackTitle: "New Tab").subtitle == "https://example.com/")
    }

    @Test func aBlankOrNewTabPageHasNoThumbnail() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        defer { page.close() }
        let key = "page"
        services.cache.install(page, for: key)
        defer { services.cache.browsers[key] = nil }
        let size = CGSize(width: 320, height: 200)
        // The hover card's thumbnails.
        let previews = TabPreviewSource(cache: services.cache)

        // A page with content: its picture is the preview, a flat capture (not painted yet) is none.
        page.load(try #require(URL(string: "data:text/html,<h1>cmux</h1>")))
        try await Self.until { page.state.url?.scheme == "data" }
        services.cache.pageThumbnails.insert(try Self.striped(), for: key)
        #expect(await previews.previewImage(for: TabID(key), maxPixelSize: size) != nil, "a page's picture was not its preview")
        services.cache.pageThumbnails.insert(try Self.flat(), for: key)
        #expect(await previews.previewImage(for: TabID(key), maxPixelSize: size) == nil, "a flat black capture was the preview")

        // The blank page (WebKit's New Tab page): no preview, not even the picture of the page before.
        services.cache.pageThumbnails.insert(try Self.striped(), for: key)
        page.load(try #require(URL(string: BrowserNewTabPage.blankURL)))
        try await Self.until { BrowserNewTabPage.isNewTabPage(page.state.url) }
        #expect(await previews.previewImage(for: TabID(key), maxPixelSize: size) == nil, "the New Tab page had a preview")

        // A terminal (#22653): a dark screen with lines of output shows, a flat capture (a shell
        // showing only its prompt over a see-through background) is none, as a flat page is.
        services.cache.previews.insert(try Self.terminalOutput(), for: "terminal")
        #expect(await previews.previewImage(for: TabID("terminal"), maxPixelSize: size) != nil, "a terminal's output was not its preview")
        services.cache.previews.insert(try Self.flat(), for: "terminal")
        #expect(await previews.previewImage(for: TabID("terminal"), maxPixelSize: size) == nil, "a flat terminal capture was the preview")
    }

    /// macOS 27 CI (#20342): a New Tab load that replaces a page still loading showed the page
    /// before. WebKit reports the New Tab address (the URL KVO) while the old load is provisional,
    /// then the old load's cancellation, which put the committed address back until the New Tab
    /// load started. These are WebKit's callbacks in its order, so it fails every time.
    @Test func aNewTabLoadThatCancelsAnUnfinishedPageShowsNoPreviewOfIt() async throws {
        _ = NSApplication.shared
        let shown = try #require(URL(string: "https://example.com/"))
        let old = try #require(URL(string: "data:text/html,<h1>cmux</h1>"))
        let blank = try #require(URL(string: BrowserNewTabPage.blankURL))
        let services = AppServices(environment: AppEnvironment.current([:]))
        let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        defer { page.close() }
        let key = "page"
        services.cache.install(page, for: key)
        defer { services.cache.browsers[key] = nil }
        services.cache.pageThumbnails.insert(try Self.striped(), for: key)
        let committed = page.allocateNavigationID()
        page.apply(.started(committed, url: shown))
        page.apply(.committed(committed, url: shown))
        page.apply(.finished(committed))
        let loading = page.allocateNavigationID()
        page.apply(.started(loading, url: old))
        page.apply(.urlChanged(blank))
        page.apply(.failed(loading, BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, message: "cancelled", failingURL: old)))
        #expect(page.state.url == blank, "the cancelled load put the page before back")
        #expect(await TabPreviewSource(cache: services.cache).previewImage(for: TabID(key), maxPixelSize: CGSize(width: 320, height: 200)) == nil,
                "the page before was the New Tab page's preview")
    }

    private static func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), "the page never got there")
    }

    private static func image(_ draw: (CGContext) -> Void) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        draw(context)
        return try #require(context.makeImage())
    }

    /// The New Tab page in a dark theme: one flat near-black color.
    static func flat() throws -> CGImage {
        try image { $0.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)); $0.fill(CGRect(x: 0, y: 0, width: 640, height: 400)) }
    }

    /// A terminal with output in a dark theme: a near-black screen with a few lines of light text
    /// at the top, the rest empty.
    static func terminalOutput() throws -> CGImage {
        try image { context in
            context.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
            context.setFillColor(CGColor(gray: 0.8, alpha: 1))
            for (line, width) in [520, 300, 460, 240, 560, 380].enumerated() {
                context.fill(CGRect(x: 16, y: 400 - 26 - line * 24, width: width, height: 10))
            }
        }
    }

    /// A page with content: dark and light bands.
    static func striped() throws -> CGImage {
        try image { context in
            for band in 0..<10 {
                context.setFillColor(band.isMultiple(of: 2) ? CGColor(gray: 0.1, alpha: 1) : CGColor(gray: 0.9, alpha: 1))
                context.fill(CGRect(x: 0, y: band * 40, width: 640, height: 40))
            }
        }
    }
}

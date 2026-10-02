import AppKit
import CmuxNextBrowser
import CmuxNextTabs
import Observation
import Testing
@testable import CmuxNextApp

/// Browser tabs show their page's favicon, a throbber while the
/// page loads, and a globe until a favicon exists (nxdog13: "browser tabs
/// need to support favicons").
@Suite struct BrowserTabIconStateTests {
    static let icon = TabImage(NSImage(size: NSSize(width: 4, height: 4)).cgImage(forProposedRect: nil, context: nil, hints: nil)
        ?? CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!)

    @Test func loadingShowsTheThrobberInPlaceOfTheFavicon() {
        #expect(BrowserTabIconState.resolve(isLoading: true, isDormant: false, favicon: Self.icon) == .throbber)
        #expect(BrowserTabIconState.resolve(isLoading: true, isDormant: false, favicon: nil) == .throbber)
    }

    @Test func aLoadedPageShowsItsFaviconElseAGlobe() {
        #expect(BrowserTabIconState.resolve(isLoading: false, isDormant: false, favicon: Self.icon) == .favicon(Self.icon))
        #expect(BrowserTabIconState.resolve(isLoading: false, isDormant: false, favicon: nil) == .globe)
    }

    @Test func aHibernatedTabNeverShowsTheThrobber() {
        #expect(BrowserTabIconState.resolve(isLoading: true, isDormant: true, favicon: Self.icon) == .favicon(Self.icon))
    }

    @Test func applyingSetsTheStripItem() {
        var item = TabItem(id: TabID("b"), title: "b", icon: .symbol("globe"))
        BrowserTabIconState.favicon(Self.icon).apply(to: &item)
        #expect(item.icon == .image(Self.icon))
        BrowserTabIconState.throbber.apply(to: &item)
        #expect(item.isBusy)
    }
}

/// Counts fetches and answers from a table.
final class StubFaviconLoader: BrowserFaviconLoading {
    var icons: [URL: NSImage] = [:]
    var requests: [(URL, BrowserProfileID)] = []

    func favicon(at url: URL, profile: BrowserProfileID) async -> NSImage? {
        requests.append((url, profile))
        return icons[url]
    }
}

@MainActor @Suite struct TabFaviconStoreTests {
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        NSColor.gray.setFill()
        NSRect(x: 0, y: 0, width: 16, height: 16).fill()
        image.unlockFocus()
        return image
    }

    /// Waits for the next change the store publishes to `read`.
    private func changed(_ read: @escaping @MainActor () -> Void) async {
        await withCheckedContinuation { continuation in
            withObservationTracking(read) { continuation.resume() }
        }
    }

    @Test func fetchesOnceAndPublishesTheIconWhenItArrives() async {
        let loader = StubFaviconLoader()
        let url = URL(string: "https://example.com/favicon.ico")!
        loader.icons[url] = Self.image()
        let store = TabFaviconStore(loader: loader)
        let address = url.absoluteString
        #expect(store.image(for: address, profile: .default) == nil, "a globe while it loads")
        await changed { _ = store.image(for: address, profile: .default) }
        let first = store.image(for: address, profile: .default)
        #expect(first != nil)
        #expect(store.image(for: address, profile: .default) === first, "stable identity: no redraw")
        #expect(loader.requests.count == 1)
    }

    @Test func profilesFetchSeparately() async {
        let loader = StubFaviconLoader()
        let url = URL(string: "https://github.com/favicon.ico")!
        loader.icons[url] = Self.image()
        let store = TabFaviconStore(loader: loader)
        let other = BrowserProfileID(rawValue: UUID())
        _ = store.image(for: url.absoluteString, profile: .default)
        await changed { _ = store.image(for: url.absoluteString, profile: .default) }
        #expect(store.image(for: url.absoluteString, profile: other) == nil)
        await changed { _ = store.image(for: url.absoluteString, profile: other) }
        #expect(loader.requests.map(\.1) == [.default, other])
    }

    @Test func aFailedIconIsNotFetchedAgainAndOnlyWebURLsAreFetched() async throws {
        let loader = StubFaviconLoader()
        let store = TabFaviconStore(loader: loader)
        let address = "https://example.com/missing.ico"
        _ = store.image(for: address, profile: .default)
        // Let the failed fetch finish.
        for _ in 0..<50 where loader.requests.isEmpty { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
        _ = store.image(for: address, profile: .default)
        #expect(loader.requests.count == 1)
        _ = store.image(for: "file:///etc/hosts", profile: .default)
        _ = store.image(for: nil, profile: .default)
        #expect(loader.requests.count == 1)
    }
}

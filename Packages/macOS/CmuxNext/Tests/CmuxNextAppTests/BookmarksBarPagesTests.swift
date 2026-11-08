import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBookmarks
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The bookmarks bar is a React page (`cmux.bookmarks-bar`) lent to the bar on screen
/// (``BookmarksBarPages``): a tab's bar is only a strip until it is in a window, tabs that take
/// turns in one pane hand the same page on, and a page shows once it laid out its tab's row.
@MainActor @Suite(.serialized)
struct BookmarksBarPagesTests {
    /// A pool whose pages load a fixture document (the bundled pages are build output).
    static func pool(services: AppServices) throws -> (BookmarksBarPages, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bookmarks-bar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Bar</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let pages = BookmarksBarPages {
            let host = BookmarkPageHostProvider(host: services, tabKey: "")
            let bar = BookmarksBarProvider(host: services, pageHost: host)
            guard let view = PageWebView(descriptor: .bookmarksBar, root: root, testRoot: true,
                                         routes: [PageRoute(prefix: BookmarksBarProvider.prefix, provider: bar)]) else { return nil }
            bar.page = view
            return BookmarksBarPage(view: view, host: host, bar: bar)
        }
        return (pages, root)
    }

    static func window() -> NSWindow {
        _ = NSApplication.shared
        return NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 40), styleMask: [.borderless], backing: .buffered, defer: true)
    }

    @Test func hiddenTabsHoldNoPageAndTabsTakingTurnsInAPaneShareOne() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let (pages, root) = try Self.pool(services: services)
        defer { try? FileManager.default.removeItem(at: root) }
        let bars = (0..<200).map { BookmarksBarHostView(tabKey: "tab-\($0)", pages: pages, profile: { "default" }) }
        #expect(pages.made == 0, "200 tabs, none shown: no page")
        let window = Self.window()
        defer { window.close() }
        let content = try #require(window.contentView)
        content.addSubview(bars[0])
        #expect(pages.made == 1 && pages.lent == 1)
        #expect(bars[0].pageView != nil)
        // The pane switches tabs: the shown tab's bar leaves, the next one's comes in.
        bars[0].removeFromSuperview()
        content.addSubview(bars[1])
        #expect(pages.made == 1, "the next tab's bar reuses the page the last one gave back")
        #expect(bars[0].pageView == nil && bars[1].pageView != nil)
        // A split shows two bars at once: two pages, never one per tab.
        content.addSubview(bars[2])
        #expect(pages.made == 2 && pages.lent == 2)
        bars[1].removeFromSuperview()
        bars[2].removeFromSuperview()
        #expect(pages.lent == 0)
    }

    @Test func theBarShowsOnceItsPageLaidOutItsRow() async throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let (pages, root) = try Self.pool(services: services)
        defer { try? FileManager.default.removeItem(at: root) }
        let bar = BookmarksBarHostView(tabKey: "tab-layout", pages: pages, profile: { "default" })
        bar.frame = NSRect(x: 0, y: 0, width: 800, height: BookmarksBarHostView.height)
        let window = Self.window()
        defer { window.close() }
        window.contentView?.addSubview(bar)
        let view = try #require(bar.pageView)
        #expect(view.alphaValue == 0, "nothing drawn for this profile yet: the strip's fill only")
        let provider = try #require(bar.page?.bar)
        let context = PageCallContext(page: PageDescriptor.bookmarksBar.id)
        _ = try await provider.call(BookmarksBarProvider.prefix + "layout", params: .object([
            "visible": .array([.object(["id": .string("bm_a"), "title": .string("GitHub"), "x": .number(2), "width": .number(70)])]),
            "overflow": .array([.string("Docs")]),
        ]), context: context)
        #expect(view.alphaValue == 1)
        #expect(bar.visibleTitles == ["GitHub"])
        #expect(bar.overflowTitles == ["Docs"])
        #expect(bar.itemFrameOnScreen("bm_a")?.width == 70)
        #expect(bar.itemFrameOnScreen("bm_missing") == nil)
        // Shown again for the same profile, the page shows at once.
        bar.removeFromSuperview()
        window.contentView?.addSubview(bar)
        #expect(bar.pageView?.alphaValue == 1)
    }
}

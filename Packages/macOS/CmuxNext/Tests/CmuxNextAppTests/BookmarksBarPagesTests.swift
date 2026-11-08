import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBookmarks
@testable import CmuxNextDaemon
@testable import CmuxNextPages
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 40), styleMask: [.borderless], backing: .buffered, defer: true)
        // ARC owns the window: a close must not release it a second time.
        window.isReleasedWhenClosed = false
        return window
    }

    /// The page's layout report of an empty row for `profile`.
    static func reportEmpty(_ provider: BookmarksBarProvider, profile: String) async throws {
        _ = try await provider.call(BookmarksBarProvider.prefix + "layout",
                                    params: .object(["profile": .string(profile), "visible": .array([]), "overflow": .array([])]),
                                    context: PageCallContext(page: PageDescriptor.bookmarksBar.id))
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
            "profile": .string("default"),
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

    /// A page lent from one profile's bar to another's shows once it reports the new profile, even
    /// when both rows are empty (the report is the same but for the profile), and a late report
    /// for the profile it left keeps it hidden.
    @Test func aPageLentToAnotherProfilesEmptyBarShowsOnItsReport() async throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let (pages, root) = try Self.pool(services: services)
        defer { try? FileManager.default.removeItem(at: root) }
        let work = BookmarksBarHostView(tabKey: "tab-work", pages: pages, profile: { "work" })
        let personal = BookmarksBarHostView(tabKey: "tab-personal", pages: pages, profile: { "personal" })
        let window = Self.window()
        defer { window.close() }
        let content = try #require(window.contentView)

        content.addSubview(work)
        let provider = try #require(work.page?.bar)
        try await Self.reportEmpty(provider, profile: "work")
        #expect(work.pageView?.alphaValue == 1)

        work.removeFromSuperview()
        content.addSubview(personal)
        #expect(pages.made == 1, "the personal tab's bar borrows the page the work tab gave back")
        let view = try #require(personal.pageView)
        #expect(view.alphaValue == 0, "the page still holds the work profile's row")
        try await Self.reportEmpty(provider, profile: "work")
        #expect(view.alphaValue == 0, "a late report for the work profile is stale here")
        try await Self.reportEmpty(provider, profile: "personal")
        #expect(view.alphaValue == 1)
        #expect(provider.drawnProfile == "personal")
        personal.removeFromSuperview()
    }

    /// A page lent to the next tab's bar keeps no gesture made in the last one's: the bar's
    /// writes need the person's own click or drop in this tab.
    @Test func aLentPageCarriesNoGestureFromTheLastTab() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let (pages, root) = try Self.pool(services: services)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = BookmarksBarHostView(tabKey: "tab-1", pages: pages, profile: { "default" })
        let second = BookmarksBarHostView(tabKey: "tab-2", pages: pages, profile: { "default" })
        let window = Self.window()
        defer { window.close() }
        let content = try #require(window.contentView)

        content.addSubview(first)
        let view = try #require(first.pageView)
        let web = view.webView
        web.noteNativeMenuSelection(at: ProcessInfo.processInfo.systemUptime)
        #expect(view.recentUserGestureEvent() != nil, "a click in the first tab's bar")

        first.removeFromSuperview()
        #expect(view.recentUserGestureEvent() == nil, "given back: the gesture is dropped")
        web.noteNativeMenuSelection(at: ProcessInfo.processInfo.systemUptime)
        content.addSubview(second)
        #expect(second.pageView === view, "the same page, lent to the next tab")
        #expect(view.recentUserGestureEvent() == nil, "lent again: no gesture from before")
        second.removeFromSuperview()
    }

    /// A host that records the bar's writes (the app's own is the daemon's `bookmarks.apply`).
    @MainActor final class BarHost: BookmarksBarHost {
        var applied: [BookmarkRoutedClient.Op] = []
        func bookmarkProfile(ofTab key: String) -> String { "default" }
        func bookmarkRows(_ ids: [String], profile: String) async throws -> [BookmarkNode] { [] }
        func bookmarkChildren(of id: String, profile: String) async throws -> [BookmarkNode] { [] }
        var bookmarkFolderIconsSupported: Bool { false }
        func bookmarkFavicon(_ node: BookmarkNode, profile: String) -> CGImage? { nil }
        func bookmarkFolderIcon(_ node: BookmarkNode, side: CGFloat) -> NSImage? { nil }
        var bookmarkIconRevision: Int { 0 }
        func openBookmark(_ node: BookmarkNode, profile: String, disposition: BookmarkOpenDisposition, fromTab key: String) {}
        func bookmarkBarContextMenu(bookmark: String?, profile: String, isFolder: Bool, icon: String?) -> NSMenu? { nil }
        func bookmarkBarApply(_ op: BookmarkRoutedClient.Op, profile: String) async throws { applied.append(op) }
        func bookmarkBarRefused(_ message: String) {}
    }

    /// A drop or a move on the bar goes through the app's bookmark write, as the daemon's op on
    /// the bar root: one write per gesture, none without one.
    @Test func aBarWriteGoesThroughTheAppOncePerGesture() async throws {
        let services = BarHost()
        let host = BookmarkPageHostProvider(host: services, tabKey: "")
        host.profileOverride = { "default" }
        let provider = BookmarksBarProvider(host: services, pageHost: host)
        let url = "https://dropped.example/"
        let create = CmuxNextSettings.JSONValue.object(["op": .object([
            "op": .string("create"), "parent": .string("bar"), "index": .number(0),
            "title": .string("Dropped"), "url": .string(url),
        ])])
        let op = BookmarksBarProvider.prefix + "apply"

        await #expect(throws: PageError.self, "no gesture: refused") {
            _ = try await provider.call(op, params: create, context: PageCallContext(page: PageDescriptor.bookmarksBar.id))
        }
        #expect(services.applied.isEmpty)

        let drop = PageCallContext(page: PageDescriptor.bookmarksBar.id, userGesture: true, gestureEvent: 10)
        _ = try await provider.call(op, params: create, context: drop)
        let made = try #require(services.applied.first?.json)
        #expect(made["op"]?.stringValue == "create" && made["parent"]?.stringValue == "bar" && made["index"]?.intValue == 0)
        #expect(made["url"]?.stringValue == url && made["browser_profile_id"]?.stringValue == "default")
        #expect(BookmarkID.isValid(made["id"]?.stringValue ?? ""), "the app mints the id, so the star can name it at once")

        let move = CmuxNextSettings.JSONValue.object(["op": .object([
            "op": .string("move"), "bookmark": .string("bm_folder"), "parent": .string("bar"), "index": .number(0),
        ])])
        await #expect(throws: PageError.self, "the drop's gesture is spent") {
            _ = try await provider.call(op, params: move, context: drop)
        }
        let click = PageCallContext(page: PageDescriptor.bookmarksBar.id, userGesture: true, gestureEvent: 11)
        _ = try await provider.call(op, params: move, context: click)
        #expect(services.applied.count == 2)
        #expect(services.applied.last?.json["op"]?.stringValue == "move")
        // Anything but a create or a move on the bar root is refused.
        let other = CmuxNextSettings.JSONValue.object(["op": .object(["op": .string("delete"), "bookmark": .string("bm_folder")])])
        await #expect(throws: PageError.self) {
            _ = try await provider.call(op, params: other, context: PageCallContext(page: PageDescriptor.bookmarksBar.id, userGesture: true, gestureEvent: 12))
        }
    }

    /// The app's side of a drop: the daemon's write, and the bar becomes the last folder (the
    /// star's next bookmark goes there); a refused drop (here: no daemon connection) throws.
    @Test func aDropMakesTheBarTheLastFolder() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let json = #"{"app":"cmux-tui","protocol":1,"session":"bar-write","generation":"g1","capabilities":["v2","bookmarks-v1"]}"#
        services.machines.local.store.noteHandshake(try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8)))
        let bookmarks = services.bookmarks
        let drop = BookmarkRoutedClient.Op.create(id: BookmarkID.make(), profile: "default", parent: BookmarkRoot.bar.rawValue,
                                                  index: 0, folder: false, title: "Dropped", url: URL(string: "https://dropped.example/"))
        await #expect(throws: PageError.self) { try await services.bookmarkBarApply(drop, profile: "default") }
        #expect(bookmarks.lastFolder["default"] == BookmarkRoot.bar.rawValue)
    }
}

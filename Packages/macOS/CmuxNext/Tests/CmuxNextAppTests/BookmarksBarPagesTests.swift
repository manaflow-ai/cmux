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

    /// A drop or a move on the bar goes through the app's bookmark write: its copy of the tree and
    /// the last folder change in the same turn (the star right after sees the new bookmark and the
    /// bar as the last folder). One write per gesture; none without one.
    @Test func aBarWriteGoesThroughTheAppOncePerGesture() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let json = #"{"app":"cmux-tui","protocol":1,"session":"bar-write","generation":"g1","capabilities":["v2","bookmarks-v1"]}"#
        services.machines.local.store.noteHandshake(try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8)))
        let bookmarks = services.bookmarks
        #expect(bookmarks.usesDaemon)
        var tree = BookmarkTree()
        let folder = BookmarkNode.folder("Work", in: BookmarkRoot.bar.rawValue)
        try tree.apply(.create(folder, index: nil))
        bookmarks.trees["default"] = tree
        bookmarks.fetched.insert("default")
        bookmarks.lastFolder["default"] = folder.id

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
        #expect(!bookmarks.isBookmarked(URL(string: url), profile: "default"))

        let drop = PageCallContext(page: PageDescriptor.bookmarksBar.id, userGesture: true, gestureEvent: 10)
        _ = try await provider.call(op, params: create, context: drop)
        #expect(bookmarks.isBookmarked(URL(string: url), profile: "default"), "the app's copy has it at once")
        #expect(bookmarks.defaultFolder(profile: "default") == BookmarkRoot.bar.rawValue, "the bar is the last folder")
        let created = try #require(bookmarks.tree("default").children(of: BookmarkRoot.bar.rawValue).first)

        let move = CmuxNextSettings.JSONValue.object(["op": .object([
            "op": .string("move"), "bookmark": .string(folder.id), "parent": .string("bar"), "index": .number(0),
        ])])
        await #expect(throws: PageError.self, "the drop's gesture is spent") {
            _ = try await provider.call(op, params: move, context: drop)
        }
        let click = PageCallContext(page: PageDescriptor.bookmarksBar.id, userGesture: true, gestureEvent: 11)
        _ = try await provider.call(op, params: move, context: click)
        #expect(bookmarks.tree("default").children(of: BookmarkRoot.bar.rawValue).map(\.id) == [folder.id, created.id])
    }

    /// A page lent to another bar of the same profile reports nothing new (its row is the same):
    /// the new bar takes the page's last report, so its item frames are right at once.
    @Test func aPageLentToAnotherBarOfTheSameProfileKeepsItsLayout() async throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let (pages, root) = try Self.pool(services: services)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = BookmarksBarHostView(tabKey: "tab-a", pages: pages, profile: { "default" })
        let second = BookmarksBarHostView(tabKey: "tab-b", pages: pages, profile: { "default" })
        let window = Self.window()
        defer { window.close() }
        let content = try #require(window.contentView)
        content.addSubview(first)
        let provider = try #require(first.page?.bar)
        _ = try await provider.call(BookmarksBarProvider.prefix + "layout", params: .object([
            "profile": .string("default"),
            "visible": .array([.object(["id": .string("bm_a"), "title": .string("GitHub"), "x": .number(2), "width": .number(70)])]),
            "overflow": .array([]),
        ]), context: PageCallContext(page: PageDescriptor.bookmarksBar.id))
        first.removeFromSuperview()
        #expect(first.visibleTitles.isEmpty, "a bar without its page shows nothing")
        content.addSubview(second)
        #expect(second.page?.bar === provider)
        #expect(second.visibleTitles == ["GitHub"])
        #expect(second.itemFrameOnScreen("bm_a")?.width == 70)
        second.removeFromSuperview()
    }

    /// The bar writes only its own row: a move of a node elsewhere (Other Bookmarks, another
    /// profile's bar) or to a slot past the row is refused and never reaches the app's write.
    @Test func aMoveOfANodeOffThisBarIsRefused() async throws {
        let host = FakeBarHost()
        let url = try #require(URL(string: "https://example.com/"))
        let a = BookmarkNode.bookmark("A", url: url, in: BookmarkRoot.bar.rawValue)
        let b = BookmarkNode.bookmark("B", url: url, in: BookmarkRoot.bar.rawValue)
        let other = BookmarkNode.folder("Elsewhere", in: BookmarkRoot.other.rawValue)
        let foreign = BookmarkNode.bookmark("X", url: url, in: BookmarkRoot.bar.rawValue)
        var tree = BookmarkTree()
        for node in [a, b, other] { try tree.apply(.create(node, index: nil)) }
        host.trees["default"] = tree
        var second = BookmarkTree()
        try second.apply(.create(foreign, index: nil))
        host.trees["p2"] = second
        let pageHost = BookmarkPageHostProvider(host: host, tabKey: "tab")
        pageHost.profileOverride = { "default" }
        let provider = BookmarksBarProvider(host: host, pageHost: pageHost)
        var event: TimeInterval = 0
        func apply(_ op: [String: CmuxNextSettings.JSONValue]) async throws {
            event += 1
            _ = try await provider.call(BookmarksBarProvider.prefix + "apply", params: .object(["op": .object(op)]),
                                        context: PageCallContext(page: PageDescriptor.bookmarksBar.id, userGesture: true, gestureEvent: event))
        }
        let move = { (id: String, index: Double) -> [String: CmuxNextSettings.JSONValue] in
            ["op": .string("move"), "bookmark": .string(id), "parent": .string("bar"), "index": .number(index)]
        }
        for (id, index) in [(other.id, 0.0), (foreign.id, 0), (a.id, 2)] {
            await #expect(throws: PageError.self, "move \(id) to \(index)") { try await apply(move(id, index)) }
        }
        await #expect(throws: PageError.self, "a create past the row") {
            try await apply(["op": .string("create"), "parent": .string("bar"), "index": .number(3),
                             "title": .string("New"), "url": .string("https://new.example/")])
        }
        #expect(host.applied.isEmpty)
        try await apply(move(a.id, 1))
        #expect(host.applied == [.move(id: a.id, parent: BookmarkRoot.bar.rawValue, index: 1)])
    }

    /// A pick in a bar menu opens nothing once the bar's page shows another tab or profile.
    @Test func aBarMenuPickOpensNothingAfterTheBarMovedOn() throws {
        _ = NSApplication.shared
        let host = FakeBarHost()
        let url = try #require(URL(string: "https://example.com/"))
        let node = BookmarkNode.bookmark("A", url: url, in: BookmarkRoot.bar.rawValue)
        var current = true
        let menu = BookmarksBarMenu(host: host, profile: "default", tabKey: "tab", rows: [.bookmark(node)], title: "Work") { current }
        menu.menuNeedsUpdate(menu.menu)
        menu.menu.performActionForItem(at: 0)
        #expect(host.opened == [node.id])
        current = false
        menu.menu.performActionForItem(at: 0)
        #expect(host.opened == [node.id], "the tab or profile changed: the pick is dropped")
    }

    /// A page returned before its new profile's row landed reports that row while it waits as a
    /// spare: the next bar of the first profile must not show it (the cached report and the
    /// profile it drew are one record).
    @Test func aReportMadeWhileSpareKeepsTheNextBarOfTheOldProfileHidden() async throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let (pages, root) = try Self.pool(services: services)
        defer { try? FileManager.default.removeItem(at: root) }
        let work = BookmarksBarHostView(tabKey: "tab-work", pages: pages, profile: { "work" })
        let personal = BookmarksBarHostView(tabKey: "tab-personal", pages: pages, profile: { "personal" })
        let workAgain = BookmarksBarHostView(tabKey: "tab-work-2", pages: pages, profile: { "work" })
        let window = Self.window()
        defer { window.close() }
        let content = try #require(window.contentView)

        content.addSubview(work)
        let provider = try #require(work.page?.bar)
        try await Self.reportEmpty(provider, profile: "work")
        work.removeFromSuperview()
        content.addSubview(personal)
        personal.removeFromSuperview()
        // The personal row lands after the page went back to the pool.
        try await Self.reportEmpty(provider, profile: "personal")
        #expect(provider.drawnProfile == "personal")

        content.addSubview(workAgain)
        let view = try #require(workAgain.pageView)
        #expect(workAgain.page?.bar === provider)
        #expect(view.alphaValue == 0, "the page shows the personal row: hidden until it reports work")
        try await Self.reportEmpty(provider, profile: "work")
        #expect(view.alphaValue == 1)
        workAgain.removeFromSuperview()
    }

    /// A middle click on the bar's page is the person's gesture: the bar opens a link in a
    /// background tab on it, and the host takes the open only with a gesture behind it.
    @Test func aMiddleClickOnTheBarIsAGesture() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let (pages, root) = try Self.pool(services: services)
        defer { try? FileManager.default.removeItem(at: root) }
        let bar = BookmarksBarHostView(tabKey: "tab-middle", pages: pages, profile: { "default" })
        bar.frame = NSRect(x: 0, y: 0, width: 800, height: BookmarksBarHostView.height)
        let window = Self.window()
        defer { window.close() }
        window.contentView?.addSubview(bar)
        let view = try #require(bar.pageView)
        #expect(view.recentUserGestureEvent() == nil)
        let event = try #require(NSEvent.mouseEvent(with: .otherMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.webView.otherMouseDown(with: event)
        #expect(view.recentUserGestureEvent() != nil)
        bar.removeFromSuperview()
    }

    /// An open whose bookmark is read from the daemon (the app's copy lags) acts for the tab it
    /// was accepted in: the page lent to another tab meanwhile opens nothing, for open and Open All.
    @Test func anOpenHeldOnTheOwnersTreeOpensNothingAfterATabSwitch() async throws {
        let host = FakeBarHost()
        let url = try #require(URL(string: "https://example.com/"))
        let folder = BookmarkNode.folder("Work", in: BookmarkRoot.bar.rawValue)
        let link = BookmarkNode.bookmark("A", url: url, in: folder.id)
        var owner = BookmarkTree()
        try owner.apply(.create(folder, index: nil))
        try owner.apply(.create(link, index: nil))
        host.ownerTrees["default"] = owner
        let pageHost = BookmarkPageHostProvider(host: host, tabKey: "tab-1")
        var event: TimeInterval = 0
        func held(_ op: String, _ params: [String: CmuxNextSettings.JSONValue], moveOn: @MainActor () -> Void) async {
            host.holdOwnerTree = true
            event += 1
            let context = PageCallContext(page: PageDescriptor.bookmarksBar.id, userGesture: true, gestureEvent: event)
            let call = Task { try await pageHost.call(BookmarkPageHostProvider.prefix + op, params: .object(params), context: context) }
            // Bounded: the call reaches the held read within a few turns, or the test fails.
            for _ in 0..<1_000 where host.waiting.isEmpty { await Task.yield() }
            #expect(!host.waiting.isEmpty, "\(op) waits on the owner's tree")
            moveOn()
            host.releaseOwnerTree()
            await #expect(throws: PageError.self, "\(op) after the page moved on") { _ = try await call.value }
        }
        await held("open", ["bookmark": .string(link.id), "url": .string(url.absoluteString), "disposition": .string("newTab")]) {
            pageHost.tabKey = "tab-2"
        }
        await held("openAll", ["folder": .string(folder.id)]) { pageHost.relend() }
        #expect(host.opened.isEmpty)

        // Not moved on: the same open goes to the tab it came from.
        host.holdOwnerTree = false
        event += 1
        _ = try await pageHost.call(BookmarkPageHostProvider.prefix + "open",
                                    params: .object(["bookmark": .string(link.id), "disposition": .string("newTab")]),
                                    context: PageCallContext(page: PageDescriptor.bookmarksBar.id, userGesture: true, gestureEvent: event))
        #expect(host.opened == [link.id])
        #expect(host.openedFrom == ["tab-2"])
    }

    /// A lend or a give-back ends every lease taken before it, even for the same tab.
    @Test func everyLendEndsTheLeasesTakenBeforeIt() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let (pages, root) = try Self.pool(services: services)
        defer { try? FileManager.default.removeItem(at: root) }
        let bar = BookmarksBarHostView(tabKey: "tab-same", pages: pages, profile: { "default" })
        let window = Self.window()
        defer { window.close() }
        let content = try #require(window.contentView)
        content.addSubview(bar)
        let pageHost = try #require(bar.page?.host)
        let lease = pageHost.lease()
        #expect(pageHost.isCurrent(lease))
        bar.removeFromSuperview()
        #expect(!pageHost.isCurrent(lease), "given back")
        content.addSubview(bar)
        #expect(bar.page?.host === pageHost)
        #expect(!pageHost.isCurrent(lease), "lent again to the same tab: still a new lend")
        bar.removeFromSuperview()
    }

    /// A menu's rows read before the page was lent again (even to a tab of the same profile) or
    /// for another profile are refused; the page learns each lend from the host's events.
    @Test func aMenuReadBeforeALendIsRefused() throws {
        let host = FakeBarHost()
        let pageHost = BookmarkPageHostProvider(host: host, tabKey: "tab-a")
        let provider = BookmarksBarProvider(host: host, pageHost: pageHost)
        let menu = { (profile: String, lend: Int) -> CmuxNextSettings.JSONValue in
            .object(["profile": .string(profile), "lend": .number(Double(lend))])
        }
        let lend = pageHost.lendGeneration
        #expect(provider.acceptsMenu(menu("default", lend)))
        #expect(!provider.acceptsMenu(menu("p2", lend)))
        #expect(!provider.acceptsMenu(.object(["profile": .string("default")])), "a menu with no lend")
        pageHost.tabKey = "tab-b"
        #expect(!provider.acceptsMenu(menu("default", lend)), "lent to a tab of the same profile")
        #expect(provider.acceptsMenu(menu("default", pageHost.lendGeneration)))
    }
}

/// A bar host that records what the bar asks of the app.
@MainActor
private final class FakeBarHost: BookmarksBarHost {
    var trees: [String: BookmarkTree] = [:]
    var applied: [BookmarkOperation] = []
    var opened: [String] = []
    var openedFrom: [String] = []
    var ownerTrees: [String: BookmarkTree] = [:]
    /// While set, an owner-tree read waits for ``releaseOwnerTree()``.
    var holdOwnerTree = false
    var waiting: [CheckedContinuation<Void, Never>] = []

    func releaseOwnerTree() {
        let held = waiting
        waiting = []
        held.forEach { $0.resume() }
    }

    func bookmarkProfile(ofTab key: String) -> String { "default" }
    func bookmarkTree(_ profile: String) -> BookmarkTree { trees[profile] ?? BookmarkTree() }
    func bookmarkOwnerTree(_ profile: String) async throws -> BookmarkTree {
        if holdOwnerTree { await withCheckedContinuation { waiting.append($0) } }
        return ownerTrees[profile] ?? bookmarkTree(profile)
    }
    var bookmarkFolderIconsSupported: Bool { false }
    func bookmarkFavicon(_ node: BookmarkNode, profile: String) -> CGImage? { nil }
    func bookmarkFolderIcon(_ node: BookmarkNode, side: CGFloat) -> NSImage? { nil }
    var bookmarkIconRevision: Int { 0 }
    func openBookmark(_ node: BookmarkNode, profile: String, disposition: BookmarkOpenDisposition, fromTab key: String) {
        opened.append(node.id)
        openedFrom.append(key)
    }
    func bookmarkBarContextMenu(bookmark: String?) -> NSMenu? { nil }
    func bookmarkBarRefused(_ message: String) {}
    func bookmarkBarApply(_ operation: BookmarkOperation, profile: String) throws { applied.append(operation) }
}

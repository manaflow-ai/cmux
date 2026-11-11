import AppKit
@testable import CmuxNextBookmarks
import Foundation
import Testing

/// The bookmarks bar is native AppKit (``BookmarksBarView``) over the app's one bookmark model
/// (``BookmarksBarHostSource``): the row lays out with what does not fit behind the chevron, a
/// folder is an `NSMenu`, and a drop or a move is the app's write.
@MainActor @Suite(.serialized)
struct BookmarksBarNativeTests {
    private static func window(width: CGFloat) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 40), styleMask: [.borderless], backing: .buffered, defer: true)
        // ARC owns the window: a close must not release it a second time.
        window.isReleasedWhenClosed = false
        return window
    }

    private static func link(_ title: String, in parent: String = BookmarkRoot.bar.rawValue) throws -> BookmarkNode {
        .bookmark(title, url: try #require(URL(string: "https://example.com/\(title.count)-\(parent)")), in: parent)
    }

    private static func host(_ nodes: [BookmarkNode]) throws -> FakeBarHost {
        let host = FakeBarHost()
        var tree = BookmarkTree()
        for node in nodes { try tree.apply(.create(node, index: nil)) }
        host.trees["default"] = tree
        return host
    }

    private static func bar(_ host: FakeBarHost, width: CGFloat) -> (BookmarksBarView, NSWindow) {
        let window = window(width: width)
        let bar = BookmarksBarView(frame: NSRect(x: 0, y: 0, width: width, height: BookmarksBarView.height))
        bar.source = BookmarksBarHostSource(host: host, tabKey: "tab-1")
        window.contentView?.addSubview(bar)
        bar.layoutSubtreeIfNeeded()
        return (bar, window)
    }

    @Test func aWideBarShowsEveryItemAndANarrowOnePutsTheRestBehindTheChevron() throws {
        let titles = (1...8).map { "Bookmark number \($0)" }
        let host = try Self.host(try titles.map { try Self.link($0) })
        let (wide, wideWindow) = Self.bar(host, width: 4000)
        defer { wideWindow.close() }
        #expect(wide.visibleTitles == titles)
        #expect(wide.overflowTitles.isEmpty)

        let (narrow, narrowWindow) = Self.bar(host, width: 260)
        defer { narrowWindow.close() }
        #expect(!narrow.overflowTitles.isEmpty, "eight items do not fit 260 points")
        #expect(narrow.visibleTitles + narrow.overflowTitles == titles, "the row keeps its order across the chevron")
    }

    @Test func aBarOffItsWindowRebuildsWhenShown() throws {
        let host = try Self.host([try Self.link("One")])
        let bar = BookmarksBarView(frame: NSRect(x: 0, y: 0, width: 800, height: BookmarksBarView.height))
        bar.source = BookmarksBarHostSource(host: host, tabKey: "tab-1")
        #expect(bar.visibleTitles.isEmpty, "a bar in no window builds nothing")
        let window = Self.window(width: 800)
        defer { window.close() }
        window.contentView?.addSubview(bar)
        bar.layoutSubtreeIfNeeded()
        #expect(bar.visibleTitles == ["One"])
    }

    @Test func aFolderIsANativeMenuWithOpenAllPastOneLinkAndEmptyForNone() throws {
        let folder = BookmarkNode.folder("Work", in: BookmarkRoot.bar.rawValue)
        let empty = BookmarkNode.folder("Later", in: folder.id)
        let host = try Self.host([folder, try Self.link("Docs", in: folder.id), try Self.link("Board", in: folder.id), empty])
        let source = BookmarksBarHostSource(host: host, tabKey: "tab-1")
        let menu = BookmarkFolderMenu(source: source, folder: folder.id, title: folder.displayTitle)
        menu.menuNeedsUpdate(menu.menu)
        let rows = menu.menu.items
        #expect(rows.map(\.title) == ["Docs", "Board", "Later", "", BookmarkStrings.openAll(2)])
        #expect(rows[3].isSeparatorItem)
        // A subfolder is a submenu that fills when it opens.
        let submenu = try #require(rows[2].submenu)
        #expect(submenu.items.isEmpty)
        submenu.delegate?.menuNeedsUpdate?(submenu)
        #expect(submenu.items.map(\.title) == [BookmarkStrings.emptyFolder])
        #expect(submenu.items.first?.isEnabled == false)
    }

    @Test func openAllOpensTheFirstInANewTabAndTheRestBehindIt() throws {
        let folder = BookmarkNode.folder("Work", in: BookmarkRoot.bar.rawValue)
        let first = try Self.link("Docs", in: folder.id)
        let second = try Self.link("Board", in: folder.id)
        let host = try Self.host([folder, first, second, .folder("Later", in: folder.id)])
        let source = BookmarksBarHostSource(host: host, tabKey: "tab-1")
        source.openAll(in: folder.id)
        #expect(host.opened == [first.id, second.id])
        #expect(host.dispositions == [.newTab, .backgroundTab])
        #expect(host.openedFrom == ["tab-1", "tab-1"])
    }

    @Test func aMoveAndADropOnTheBarAreTheAppsWrite() throws {
        let one = try Self.link("One")
        let host = try Self.host([one, try Self.link("Two")])
        let source = BookmarksBarHostSource(host: host, tabKey: "tab-1")
        source.moveToBar(one.id, index: 1)
        #expect(host.applied == [.move(id: one.id, parent: BookmarkRoot.bar.rawValue, index: 1)])
        let url = try #require(URL(string: "https://example.org/dropped"))
        source.addToBar(url: url, title: "Dropped", index: 0)
        guard case .create(let node, let index)? = host.applied.last else {
            Issue.record("a dropped link is a create")
            return
        }
        #expect(node.url == url)
        #expect(node.title == "Dropped")
        #expect(node.parent == BookmarkRoot.bar.rawValue)
        #expect(index == 0)
    }

    @Test func aStandInIconLandsOnceTheAppHasIt() throws {
        let one = try Self.link("One")
        let host = try Self.host([one])
        let source = BookmarksBarHostSource(host: host, tabKey: "tab-1")
        _ = source.bookmarkChildren(of: BookmarkRoot.bar.rawValue)
        _ = source.favicon(for: one)
        #expect(!source.awaitedIconsLanded, "no icon yet: nothing to redraw")
        host.favicon = NSImage(size: NSSize(width: 1, height: 1), flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            return true
        }.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #expect(source.awaitedIconsLanded, "the icon the bar drew a stand-in for is here")
        // The rebuild reads the row again and draws the icon: nothing is awaited after it.
        _ = source.bookmarkChildren(of: BookmarkRoot.bar.rawValue)
        _ = source.favicon(for: one)
        #expect(!source.awaitedIconsLanded)
    }
}

/// A bar host that records what the bar asks of the app.
@MainActor
private final class FakeBarHost: BookmarksBarHost {
    var trees: [String: BookmarkTree] = [:]
    var applied: [BookmarkOperation] = []
    var opened: [String] = []
    var openedFrom: [String] = []
    var dispositions: [BookmarkOpenDisposition] = []
    var favicon: CGImage?

    func bookmarkProfile(ofTab key: String) -> String { "default" }
    func bookmarkTree(_ profile: String) -> BookmarkTree { trees[profile] ?? BookmarkTree() }
    func bookmarkOwnerTree(_ profile: String) async throws -> BookmarkTree { bookmarkTree(profile) }
    var bookmarkFolderIconsSupported: Bool { false }
    func bookmarkFavicon(_ node: BookmarkNode, profile: String) -> CGImage? { favicon }
    func bookmarkFolderIcon(_ node: BookmarkNode, side: CGFloat) -> NSImage? { nil }
    var bookmarkIconRevision: Int { 0 }
    func openBookmark(_ node: BookmarkNode, profile: String, disposition: BookmarkOpenDisposition, fromTab key: String) {
        opened.append(node.id)
        openedFrom.append(key)
        dispositions.append(disposition)
    }
    func bookmarkBarContextMenu(bookmark: String?) -> NSMenu? { nil }
    func bookmarkBarApply(_ operation: BookmarkOperation, profile: String) { applied.append(operation) }
}

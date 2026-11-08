import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextBookmarks
import CmuxNextTestSupport
import Foundation
import Testing

/// An empty bookmarks bar takes no room under the toolbar
/// (https://github.com/manaflow-ai/cmux/issues/38046): with `browser.showBookmarksBar` on and no
/// bookmarks, every browser tab showed a bar that only read "Drag a link here or click the star to
/// add bookmarks". The bar now attaches while the setting is on and the tab's profile has something
/// to show, and comes and goes with the first and last bookmark.
@MainActor @Suite(.serialized)
struct BookmarksBarEmptyTests {
    private static func page() -> BrowserEntry {
        _ = NSApplication.shared
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/")))
        return BrowserEntry(tab: tab)
    }

    private static func tree(_ nodes: [BookmarkNode]) throws -> BookmarkTree {
        var tree = BookmarkTree()
        for node in nodes { try tree.apply(.create(node, index: nil)) }
        return tree
    }

    @Test func anEmptyBarIsNotAttachedAndTheFirstBookmarkBringsItBack() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let bookmarks = services.bookmarks
        let entry = Self.page()
        defer { entry.close() }
        bookmarks.setBarShown(true)
        bookmarks.attach(entry)
        let profile = bookmarks.profile(of: entry.tab.profileID)
        #expect(bookmarks.isBarShown, "the setting stays on")
        #expect(entry.state.accessory == nil, "no bookmarks: no bar under the toolbar")

        let page = BookmarkNode.bookmark("Example", url: try #require(URL(string: "https://example.com/")), in: BookmarkRoot.bar.rawValue)
        bookmarks.trees[profile] = try Self.tree([page])
        bookmarks.changed(profiles: [profile])
        #expect(entry.state.accessory?.view === bookmarks.bar(ofTab: entry.tab.id.rawValue), "the first bookmark shows the bar")

        bookmarks.trees[profile] = BookmarkTree()
        bookmarks.changed(profiles: [profile])
        #expect(entry.state.accessory == nil, "deleting the last bookmark hides it again")
    }

    @Test func otherBookmarksAloneKeepTheBar() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let bookmarks = services.bookmarks
        let entry = Self.page()
        defer { entry.close() }
        let profile = bookmarks.profile(of: entry.tab.profileID)
        let other = BookmarkNode.bookmark("Elsewhere", url: try #require(URL(string: "https://example.org/")), in: BookmarkRoot.other.rawValue)
        bookmarks.trees[profile] = try Self.tree([other])
        bookmarks.attach(entry)
        #expect(entry.state.accessory == nil, "the setting is off by default")
        bookmarks.setBarShown(true)
        #expect(entry.state.accessory != nil, "the bar shows its Other Bookmarks button")
        bookmarks.setBarShown(false)
        #expect(entry.state.accessory == nil, "turning the setting off hides a bar with bookmarks")
    }
}

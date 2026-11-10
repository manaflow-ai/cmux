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
/// to show (the daemon's `bookmarks.status` says `bar_filled`), and comes and goes with the first
/// and last bookmark.
@MainActor @Suite(.serialized)
struct BookmarksBarEmptyTests {
    private static func page() -> BrowserEntry {
        _ = NSApplication.shared
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/")))
        return BrowserEntry(tab: tab)
    }

    private static func status(_ revision: Int, filled: Bool) -> BookmarkRoutedClient.Status {
        BookmarkRoutedClient.Status(revision: revision, barFilled: filled, matches: [:])
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

        bookmarks.applyStatus(Self.status(1, filled: true), profile: profile)
        #expect(entry.state.accessory?.view === bookmarks.bar(ofTab: entry.tab.id.rawValue), "the first bookmark shows the bar")

        bookmarks.applyStatus(Self.status(2, filled: false), profile: profile)
        #expect(entry.state.accessory == nil, "deleting the last bookmark hides it again")

        bookmarks.applyStatus(Self.status(1, filled: true), profile: profile)
        #expect(entry.state.accessory == nil, "an older answer that lands late changes nothing")
    }

    @Test func aFilledBarFollowsTheSetting() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let bookmarks = services.bookmarks
        let entry = Self.page()
        defer { entry.close() }
        let profile = bookmarks.profile(of: entry.tab.profileID)
        bookmarks.applyStatus(Self.status(1, filled: true), profile: profile)
        bookmarks.attach(entry)
        #expect(entry.state.accessory == nil, "the setting is off by default")
        bookmarks.setBarShown(true)
        #expect(entry.state.accessory != nil, "the bar shows its Other Bookmarks button")
        bookmarks.setBarShown(false)
        #expect(entry.state.accessory == nil, "turning the setting off hides a bar with bookmarks")
    }

    /// The star's own edit shows in the same frame, before the daemon answers: the bar of an empty
    /// profile attaches and the star turns on at once.
    @Test func theStarsBookmarkShowsTheBarAndTheStarInTheSameFrame() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let bookmarks = services.bookmarks
        let entry = Self.page()
        defer { entry.close() }
        bookmarks.setBarShown(true)
        bookmarks.attach(entry)
        let profile = bookmarks.profile(of: entry.tab.profileID)
        let url = try #require(entry.tab.state.url)
        #expect(entry.state.bookmarkStar == .off, "an unknown page's star is off, never hidden")
        bookmarks.noteBookmarks([BookmarkID.make()], url: url, profile: profile, barFilled: true)
        #expect(entry.state.bookmarkStar == .on)
        #expect(entry.state.accessory != nil)
        bookmarks.noteBookmarks([], url: url, profile: profile)
        #expect(entry.state.bookmarkStar == .off, "Remove turns it off at once")
    }
}

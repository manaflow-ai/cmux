import AppKit
import CmuxNextBookmarks
import CmuxNextBrowser
import CmuxNextDaemon

extension InternalPageID {
    /// History as a top page (TOP-SECTION-ITEMS-ARE-PAGES Q3).
    static let history = InternalPageID(rawValue: "history")
    /// Bookmarks as a top page (Q3).
    static let bookmarks = InternalPageID(rawValue: "bookmarks")
}

/// The History page as a top page: the same `HistoryPageTab` the
/// `cmux://history` browser tab shows, keyed by the top page key. A link
/// out of it opens in the window's workspace (`TopPages.leave`).
@MainActor
final class HistoryTopPage: InternalPageProvider {
    private weak var services: AppServices?
    private var pages: [String: HistoryPageTab] = [:]

    init(services: AppServices) { self.services = services }

    var page: InternalPageID { .history }
    var title: String { HistoryPageStrings.title }
    var symbol: String { "clock" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let services else { return NSView() }
        let page = HistoryPageTab(id: BrowserTabID(rawValue: key), engine: .webkit, profile: .default, source: services.historyPage,
                                  webPage: PageFactory(services: services).historyWebPage())
        page.onNavigate = { [weak services] url in
            guard let services else { return }
            HistoryRestorer(services: services).openPage(url.absoluteString, profile: nil, newTab: true)
        }
        page.webPage?.onOpenExternal = page.onNavigate
        pages[key] = page
        return page.contentView
    }

    func tabClosed(_ key: String) { pages[key] = nil }
}

/// The Bookmarks manager as a top page, over the bookmarks of the window's
/// current workspace's browser profile (`TopPages.bookmarkProfile`).
@MainActor
final class BookmarksTopPage: InternalPageProvider {
    private weak var services: AppServices?
    private var pages: [String: BookmarkPageTab] = [:]

    init(services: AppServices) { self.services = services }

    var page: InternalPageID { .bookmarks }
    var title: String { BookmarkStrings.pageTitle }
    var symbol: String { "book" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let services else { return NSView() }
        let page = services.bookmarkPages.makeTopPage(key: key, profile: { [weak services, weak window] in
            guard let services, let window else { return BrowserProfileRecord.defaultID }
            return TopPages.bookmarkProfile(of: window, services: services)
        })
        page.onNavigate = { [weak services, weak page] url in
            guard let services, let page else { return }
            BookmarkOpener(services: services).open(url, profile: page.source.profile, disposition: .newTab)
        }
        pages[key] = page
        return page.contentView
    }

    func tabClosed(_ key: String) { pages[key] = nil }
}

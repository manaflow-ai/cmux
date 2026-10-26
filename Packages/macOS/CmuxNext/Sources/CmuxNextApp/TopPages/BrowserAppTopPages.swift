import AppKit
import CmuxNextBookmarks
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextHibernation
import CmuxNextHistory
import CmuxNextIcons

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
    private(set) var pages: [String: HistoryPageTab] = [:]

    init(services: AppServices) { self.services = services }

    var page: InternalPageID { .history }
    var title: String { HistoryPageStrings.title }
    var symbol: String { "clock" }
    var icon: IconName? { .history }

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

    // MARK: Discard (p07-memory-025)

    /// Ten minutes hidden, as a browser tab (Chrome's proactive_discarding_policy.cc): the page
    /// reads the history again when it is made, so nothing but its view state is kept.
    func discardPolicy(for key: String) -> ContentDiscardPolicy { .standard }

    /// The native page's search, filter and selection with its scroll; the React page keeps its
    /// own search in its document, so it gives only the default scroll.
    func saveViewState(for key: String, content: NSView) async -> ContentViewState {
        var state = ContentViewState(scroll: content.firstScrollView?.documentVisibleRect.origin)
        guard let model = pages[key].flatMap({ $0.webPage == nil ? $0.model : nil }) else { return state }
        state.search = model.text
        state.selection = model.selection
        state.values[Self.filterValue] = model.filter.rawValue
        return state
    }

    func restoreViewState(_ state: ContentViewState, for key: String, content: NSView) {
        if let model = pages[key].flatMap({ $0.webPage == nil ? $0.model : nil }) {
            if let filter = state.values[Self.filterValue].flatMap(HistoryPageModel.Filter.init(rawValue:)) { model.filter = filter }
            if let search = state.search { model.text = search }
            model.selection = state.selection
        }
        content.scrollFirstScrollView(to: state.scroll)
    }

    /// The tab stays and its page goes; the next show makes a new one.
    func viewDiscarded(_ key: String) { pages[key] = nil }

    static let filterValue = "filter"
}

/// The Bookmarks manager as a top page, over the bookmarks of the window's
/// current workspace's browser profile (`TopPages.bookmarkProfile`).
@MainActor
final class BookmarksTopPage: InternalPageProvider {
    private weak var services: AppServices?
    private(set) var pages: [String: BookmarkPageTab] = [:]

    init(services: AppServices) { self.services = services }

    var page: InternalPageID { .bookmarks }
    var title: String { BookmarkStrings.pageTitle }
    var symbol: String { "book" }
    var icon: IconName? { .bookmarkManager }

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

    // MARK: Discard (p07-memory-025)

    /// Ten minutes hidden, as a browser tab (Chrome's proactive_discarding_policy.cc): the
    /// bookmarks are read again when the page is made, so only its view state is kept.
    func discardPolicy(for key: String) -> ContentDiscardPolicy { .standard }

    /// The shown folder, the search, the selected bookmarks (ids, one per line) and the scroll.
    func saveViewState(for key: String, content: NSView) async -> ContentViewState {
        var state = ContentViewState(scroll: content.firstScrollView?.documentVisibleRect.origin)
        guard let model = pages[key]?.model else { return state }
        state.values[Self.folderValue] = model.folder
        state.search = model.query
        state.selection = model.selection.isEmpty ? nil : model.selection.sorted().joined(separator: "\n")
        return state
    }

    func restoreViewState(_ state: ContentViewState, for key: String, content: NSView) {
        if let model = pages[key]?.model {
            if let folder = state.values[Self.folderValue], model.tree.isContainer(folder) { model.folder = folder }
            if let search = state.search { model.query = search }
            let selected = state.selection.map { $0.split(separator: "\n").map(String.init) } ?? []
            model.selection = Set(selected.filter { model.tree.node($0) != nil })
        }
        content.scrollFirstScrollView(to: state.scroll)
    }

    /// The tab stays and its page goes; the next show makes a new one.
    func viewDiscarded(_ key: String) { pages[key] = nil }

    static let folderValue = "folder"
}

private extension NSView {
    /// Scrolls the first scroll view in this view's tree to `origin`, the scroll part of a page's
    /// default view state (``InternalPageProvider/restoreViewState(_:for:content:)``).
    func scrollFirstScrollView(to origin: CGPoint?) {
        guard let origin, let scroll = firstScrollView else { return }
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

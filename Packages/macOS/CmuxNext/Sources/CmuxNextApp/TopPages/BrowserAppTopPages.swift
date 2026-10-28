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

    // MARK: Discard

    /// Ten minutes hidden, as a browser tab (Chrome's proactive_discarding_policy.cc): the page
    /// reads the history again when it is made, so nothing but its view state is kept.
    func discardPolicy(for key: String) -> ContentDiscardPolicy { .standard }

    /// The native page's search, filter, selection and list scroll. The React page
    /// (`history.surface = web`, a Debug setting) keeps none: its search lives only in its
    /// document, which closes with the view, so it comes back on its start.
    func saveViewState(for key: String, content: NSView) async -> ContentViewState {
        guard let model = nativeModel(key) else { return ContentViewState() }
        return ContentViewState(scroll: content.listScrollView?.documentVisibleRect.origin, search: model.text,
                                selection: model.selection, values: [Self.filterValue: model.filter.rawValue])
    }

    /// One reload for the saved search and filter; the selection and the scroll go back once its
    /// rows are in (before, the list is empty and the scroll clamps to the top).
    func restoreViewState(_ state: ContentViewState, for key: String, content: NSView) {
        guard let model = nativeModel(key) else { return }
        let filter = state.values[Self.filterValue].flatMap(HistoryPageModel.Filter.init(rawValue:)) ?? model.filter
        model.restore(text: state.search ?? model.text, filter: filter, selection: state.selection) { [weak content] in
            guard let content else { return }
            // sync-layout: restoreScroll reads the list's laid-out height; before it, the scroll clamps to the top.
            content.layoutSubtreeIfNeeded()
            content.listScrollView?.restoreScroll(state.scroll)
        }
    }

    private func nativeModel(_ key: String) -> HistoryPageModel? {
        pages[key].flatMap { $0.webPage == nil ? $0.model : nil }
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

    // MARK: Discard

    /// Ten minutes hidden, as a browser tab (Chrome's proactive_discarding_policy.cc): the
    /// bookmarks are read again when the page is made, so only its view state is kept.
    func discardPolicy(for key: String) -> ContentDiscardPolicy { .standard }

    /// An open add or edit sheet keeps the view: its typed title and URL live in the sheet.
    func keepReasons(for key: String) -> [CannotDiscardReason] {
        pages[key]?.model.editor == nil ? [] : [.unsavedEdits]
    }

    /// The shown folder, the search, the selected bookmarks (ids, one per line) and the list scroll.
    func saveViewState(for key: String, content: NSView) async -> ContentViewState {
        guard let model = pages[key]?.model else { return ContentViewState() }
        return ContentViewState(scroll: content.listScrollView?.documentVisibleRect.origin, search: model.query,
                                selection: model.selection.isEmpty ? nil : model.selection.sorted().joined(separator: "\n"),
                                values: [Self.folderValue: model.folder])
    }

    /// The page reads the bookmarks when it is made, so the state goes back at once (the rows of
    /// the restored folder laid out first); a folder or bookmark gone from the tree is dropped.
    func restoreViewState(_ state: ContentViewState, for key: String, content: NSView) {
        guard let model = pages[key]?.model else { return }
        if let folder = state.values[Self.folderValue], model.tree.isContainer(folder) { model.folder = folder }
        if let search = state.search { model.query = search }
        let selected = state.selection.map { $0.split(separator: "\n").map(String.init) } ?? []
        model.selection = Set(selected.filter { model.tree.node($0) != nil })
        // sync-layout: restoreScroll reads the restored folder's laid-out rows; before them, the scroll clamps.
        content.layoutSubtreeIfNeeded()
        content.listScrollView?.restoreScroll(state.scroll)
    }

    /// The tab stays and its page goes; the next show makes a new one.
    func viewDiscarded(_ key: String) { pages[key] = nil }

    static let folderValue = "folder"
}

import AppKit
import CmuxNextBookmarks
import CmuxNextBridge
import CmuxNextBrowser
import Foundation
import UniformTypeIdentifiers

/// Opens `cmux://bookmarks` and keeps open manager pages current.
@MainActor
final class BookmarkPageService {
    private unowned let services: AppServices
    /// Live manager pages (weak), reloaded when their profile changes.
    private var pages: [WeakPage] = []

    private final class WeakPage {
        weak var page: BookmarkPageTab?
        init(_ page: BookmarkPageTab) { self.page = page }
    }

    init(services: AppServices) {
        self.services = services
    }

    /// Selects the active window's manager tab, else opens one beside the
    /// focused tab (or in it, when that tab is a New Tab page). `selecting`
    /// shows that node's folder with it selected.
    func open(selecting id: String? = nil) {
        guard let window = services.windows.active else { return services.registry.refuse(RefusalStrings.noWindowOpen) }
        for pane in window.content?.panes.values.map({ $0 }) ?? [] {
            if let tab = pane.pane.tabs.first(where: { BookmarkPageAddress.matches($0.url.flatMap(URL.init(string:))) }) {
                pane.select(StripTabID(tab.id))
                if let id, let page = services.cache.existingBrowser(tab.id)?.tab as? BookmarkPageTab { reveal(id, in: page) }
                return
            }
        }
        guard let pane = window.focusedPane else { return }
        if let tab = pane.selectedTab, tab.kind == .browser, let page = services.cache.existingBrowser(tab.id)?.tab,
           BrowserNewTabPage.isNewTabPage(page.state.url) {
            services.cache.showAppPage(BookmarkPageAddress.url, in: tab)
            return
        }
        pane.newBrowserTab(url: BookmarkPageAddress.url)
    }

    private func reveal(_ id: String, in page: BookmarkPageTab) {
        page.model.reload()
        guard let node = page.model.tree.node(id) else { return }
        page.model.query = ""
        page.model.folder = node.parent
        page.model.selection = [id]
    }

    /// A manager page for tab `key`.
    func makePage(key: String, engine: BrowserEngineKind, profile: BrowserProfileID) -> BookmarkPageTab {
        let source = BookmarkManagerSourceAdapter(services: services, tabKey: key)
        let page = BookmarkPageTab(id: BrowserTabID(rawValue: key), engine: engine, profile: profile, source: source)
        pages = pages.filter { $0.page != nil } + [WeakPage(page)]
        return page
    }

    /// A manager page for top page `key` (no tab): `profile` names the
    /// bookmarks it shows (the window's workspace's browser profile).
    func makeTopPage(key: String, profile: @escaping @MainActor () -> String) -> BookmarkPageTab {
        let source = BookmarkManagerSourceAdapter(services: services, tabKey: key)
        source.profileOverride = profile
        let page = BookmarkPageTab(id: BrowserTabID(rawValue: key), engine: .webkit, profile: .default, source: source)
        pages = pages.filter { $0.page != nil } + [WeakPage(page)]
        return page
    }

    func reload(profiles: Set<String>) {
        for weak in pages {
            guard let page = weak.page, profiles.contains(page.source.profile) else { continue }
            page.model.reload()
        }
    }
}

/// One manager page's source: the tab's browser profile.
@MainActor
final class BookmarkManagerSourceAdapter: BookmarkManagerSource {
    private unowned let services: AppServices
    let tabKey: String

    init(services: AppServices, tabKey: String) {
        self.services = services
        self.tabKey = tabKey
    }

    /// A top page's source names its profile; a tab's source uses the tab's.
    var profileOverride: (@MainActor () -> String)?

    var profile: String { profileOverride?() ?? services.bookmarks.profile(ofTab: tabKey) }

    var managerTree: BookmarkTree { services.bookmarks.tree(profile) }

    func apply(_ operation: BookmarkOperation) -> Bool {
        do {
            try services.bookmarks.apply(operation, profile: profile)
            return true
        } catch {
            services.registry.refuse(BookmarkAppStrings.failure(error))
            return false
        }
    }

    func open(_ node: BookmarkNode, disposition: BookmarkOpenDisposition) {
        BookmarkOpener(services: services).open(node, profile: profile, disposition: disposition, fromTab: tabKey)
    }

    func openAll(in folder: String) {
        BookmarkOpener(services: services).openAll(in: folder, profile: profile, fromTab: tabKey)
    }

    func importHTML() { BookmarkFiles(services: services).chooseImport(profile: profile) }
    func exportHTML() { BookmarkFiles(services: services).chooseExport(profile: profile) }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

import AppKit
import CmuxNextActions
import CmuxNextBookmarks
import CmuxNextBridge
import CmuxNextBrowser
import Foundation
import UniformTypeIdentifiers

/// Opens `cmux://bookmarks` and keeps open manager pages current.
@MainActor
final class BookmarkPageService {
    private let servicesReference: AppServicesReference
    /// The app's services, which own this; nil (reported) only once they are gone.
    private var services: AppServices? { servicesReference.resolve() }
    /// Live manager pages (weak), reloaded when their profile changes.
    private var pages: [WeakPage] = []

    private final class WeakPage {
        weak var page: BookmarkPageTab?
        init(_ page: BookmarkPageTab) { self.page = page }
    }

    init(services: AppServices) {
        servicesReference = AppServicesReference(services)
    }

    /// Selects the active window's manager tab, else opens one beside the
    /// focused tab (or in it, when that tab is a New Tab page). `selecting`
    /// shows that node's folder with it selected.
    func open(selecting id: String? = nil) {
        guard let services else { return }
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
        let source = BookmarkManagerSourceAdapter(services: servicesReference, tabKey: key)
        let page = BookmarkPageTab(id: BrowserTabID(rawValue: key), engine: engine, profile: profile, source: source)
        pages = pages.filter { $0.page != nil } + [WeakPage(page)]
        return page
    }

    /// A manager page for top page `key` (no tab): `profile` names the
    /// bookmarks it shows (the window's workspace's browser profile).
    func makeTopPage(key: String, profile: @escaping @MainActor () -> String) -> BookmarkPageTab {
        let source = BookmarkManagerSourceAdapter(services: servicesReference, tabKey: key)
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
    private let servicesReference: AppServicesReference
    /// The app's services, which own this; nil (reported) only once they are gone.
    private var services: AppServices? { servicesReference.resolve() }
    let tabKey: String

    init(services: AppServices, tabKey: String) {
        servicesReference = AppServicesReference(services)
        self.tabKey = tabKey
    }

    /// A source of the page service's pages, which share its reference to the services.
    init(services: AppServicesReference, tabKey: String) {
        servicesReference = services
        self.tabKey = tabKey
    }

    /// A top page's source names its profile; a tab's source uses the tab's.
    var profileOverride: (@MainActor () -> String)?

    var profile: String {
        if let profileOverride { return profileOverride() }
        return services?.bookmarks.profile(ofTab: tabKey) ?? BrowserProfileRecord.defaultID
    }

    var managerTree: BookmarkTree { services?.bookmarks.tree(profile) ?? BookmarkTree() }

    func favicon(for node: BookmarkNode) -> CGImage? {
        guard let services else { return nil }
        if node.isFolder { return services.bookmarks.folderIconCGImage(of: node) }
        return services.bookmarks.favicon(of: node, profile: profile, fetching: true)?.cgImage
    }

    var canSetFolderIcons: Bool { services?.bookmarks.supportsFolderIcons ?? false }

    /// Set Icon and Remove Icon on a folder row run the same actions as the bar's menu.
    func setIcon(of node: BookmarkNode) { perform("bookmark.setIcon", on: node) }
    func removeIcon(of node: BookmarkNode) { perform("bookmark.clearIcon", on: node) }

    private func perform(_ id: ActionID, on node: BookmarkNode) {
        guard let services else { return }
        services.registry.perform(id, invocation: ActionInvocation(target: ActionTargetRef(kind: .bookmark, id: node.id)))
    }

    func apply(_ operation: BookmarkOperation) -> Bool {
        guard let services else { return false }
        do {
            try services.bookmarks.apply(operation, profile: profile)
            return true
        } catch {
            services.registry.refuse(BookmarkAppStrings.failure(error))
            return false
        }
    }

    func open(_ node: BookmarkNode, disposition: BookmarkOpenDisposition) {
        guard let services else { return }
        BookmarkOpener(services: services).open(node, profile: profile, disposition: disposition, fromTab: tabKey)
    }

    func openAll(in folder: String) {
        guard let services else { return }
        BookmarkOpener(services: services).openAll(in: folder, profile: profile, fromTab: tabKey)
    }

    /// The ⋮ menu's rows run the registered actions on this page's profile; Add Bookmark and New
    /// Folder add to `folder` and ask for the rest in the palette, as from the bookmarks bar.
    func moreMenu(folder: String) -> NSMenu? {
        services?.registry.makeContextMenu(for: .bookmarkManager, arguments: ["folder": .string(folder), "profile": .string(profile)])
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

import AppKit
import CmuxNextActions
import CmuxNextBookmarks
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextPages
import Foundation

/// Opens `cmux://bookmarks` and makes its pages (the React manager, ``PageDescriptor/bookmarks``).
@MainActor
final class BookmarkPageService {
    private unowned let services: AppServices
    /// The bookmark the next manager page shows (``open(selecting:)`` of a new page).
    private var pendingReveal: String?

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
                if let id, let page = services.cache.existingBrowser(tab.id)?.tab as? BookmarkPageTab { page.reveal(id) }
                return
            }
        }
        guard let pane = window.focusedPane else { return }
        pendingReveal = id
        if let tab = pane.selectedTab, tab.kind == .browser, let page = services.cache.existingBrowser(tab.id)?.tab,
           BrowserNewTabPage.isNewTabPage(page.state.url) {
            services.cache.showAppPage(BookmarkPageAddress.url, in: tab)
            return
        }
        pane.newBrowserTab(url: BookmarkPageAddress.url)
    }

    /// A manager page for tab `key`; `reveal` shows that bookmark once the page has its tree.
    func makePage(key: String, engine: BrowserEngineKind, profile: BrowserProfileID) -> BookmarkPageTab {
        let host = BookmarkPageHostProvider(host: services, tabKey: key)
        let reveal = pendingReveal
        pendingReveal = nil
        return BookmarkPageTab(id: BrowserTabID(rawValue: key), engine: engine, profile: profile, host: host,
                               webPage: webPage(host, reveal: reveal))
    }

    /// A manager page for top page `key` (no tab): `profile` names the
    /// bookmarks it shows (the window's workspace's browser profile).
    func makeTopPage(key: String, profile: @escaping @MainActor () -> String) -> BookmarkPageTab {
        let host = BookmarkPageHostProvider(host: services, tabKey: key)
        host.profileOverride = profile
        return BookmarkPageTab(id: BrowserTabID(rawValue: key), engine: .webkit, profile: .default, host: host,
                               webPage: webPage(host, reveal: nil))
    }

    /// The page's routes: the tree to the daemon relay, `cmux.bookmarkPage.` to `host`, the
    /// native steps (the page's registry actions, the clipboard) to the app.
    private func webPage(_ host: BookmarkPageHostProvider, reveal: String?) -> PageWebView? {
        let relay = DaemonPageRelay(services: services)
        let native = AppPageNativeProvider(services: services, page: .bookmarks)
        native.forward = { op, params, context in try await relay.call(op, params: params, context: context) }
        let routes = [PageRoute(prefix: "cmux.bookmarks.", provider: relay),
                      PageRoute(prefix: BookmarkPageHostProvider.prefix, provider: host),
                      PageRoute(prefix: "cmux.app.", provider: native)]
        let route = reveal.flatMap { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) }.map { "#/?reveal=" + $0 }
        guard let page = PageWebView(descriptor: .bookmarks, routes: routes, route: route) else { return nil }
        native.anchor = { [weak page] in page }
        PageConnectionWatch(page: page, store: services.machines.local.store).start()
        return page
    }
}

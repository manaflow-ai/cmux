import AppKit
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextDiff
import CmuxNextGitHubViewer
import CmuxNextIcons
import CmuxNextPages
import CmuxNextSettings

/// A React page as an internal page tab, one view per tab: `make` builds each tab's page with its
/// routes, and a closed tab closes its page. The Stats, Chief Usage, Chief view gallery, channels
/// and CodeRouter tabs are this; a page with routes or sub-views of its own has its own provider.
@MainActor
final class WebPageTab: InternalPageProvider {
    let page: InternalPageID
    let symbol: String
    let icon: IconName?
    /// Read once, when the tab registers: page titles do not change while the app runs.
    let title: String
    private let make: (_ key: String, _ route: String?) -> NSView?
    private var pages: [String: NSView] = [:]
    /// What each tab of a routed page shows (its `#/...` route), so a restored or reopened tab shows it again.
    private var routes: [String: String] = [:]
    /// A page's report of what it drew (the GitHub page's `shown`: an address, and whether it had its
    /// content), for the instant-create bench's mark.
    var onShown: ((_ url: String, _ content: Bool) -> Void)?

    convenience init(_ page: InternalPageID, symbol: String, icon: IconName? = nil, title: String, make: @escaping () -> PageWebView?) {
        self.init(page, symbol: symbol, icon: icon, title: title, routed: { _, _ in make() })
    }

    /// A page whose tabs are native views made per tab `key` (the native New Tab page).
    convenience init(_ page: InternalPageID, symbol: String, icon: IconName? = nil, title: String, view make: @escaping (String) -> NSView?) {
        self.init(page, symbol: symbol, icon: icon, title: title, routed: { key, _ in make(key) })
    }

    /// A page whose tabs each show a route (``navigate(_:to:)``), made per tab `key` with its route.
    init(_ page: InternalPageID, symbol: String, icon: IconName? = nil, title: String,
         routed make: @escaping (_ key: String, _ route: String?) -> NSView?) {
        self.page = page
        self.symbol = symbol
        self.icon = icon
        self.title = title
        self.make = make
    }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let view = make(key, routes[key]) else { return NSView() }
        pages[key] = view
        return view
    }

    func route(for key: String) -> String? { routes[key] }
    func restore(_ route: String, for key: String) { routes[key] = route }

    /// Moves tab `key` to `route`: a route change in its page when it runs, else what it opens with.
    func navigate(_ key: String, to route: String) {
        routes[key] = route
        (pages[key] as? PageWebView)?.open(route: route)
    }

    func tabClosed(_ key: String) {
        (pages.removeValue(forKey: key) as? PageWebView)?.close()
        routes[key] = nil
    }
}

extension InternalPageID {
    static let github = InternalPageID(rawValue: "github")
}

/// The GitHub page (``GitHubPageProvider``) as an internal page tab (Leo, 2026-11-05: "is there a
/// sort of speed-run route ... for that type of link specifically?"). A pull request link clicked in
/// an agent chat opens here instead of loading github.com: the workspace's GitHub tab moves to the
/// link's route, a route change in a page already running, else one opens where the link's web tab
/// would have (``LinkOpener``, beside the chat).
extension WebPageTab {
    /// The page's provider, registered at launch so a restored GitHub tab has its page.
    @discardableResult
    static func registerGitHub(_ services: AppServices) -> WebPageTab {
        if let tab = services.pages.provider(.github) as? WebPageTab { return tab }
        let tab = WebPageTab(.github, symbol: "arrow.triangle.pull", title: GitHubPageProvider.title) { [weak services] _, route in
            guard let services else { return nil }
            let opener = services.linkOpener
            let provider = GitHubPageProvider(diffReader: { await AgentChatPullRequestReader().diff(url: $0) }, openWeb: { url, view in
                // Open on GitHub: the web page, as the chat's own card opens it (the GitHub tab of that pull request, if any).
                opener.openWeb(url, from: view.flatMap(opener.source(containing:)), background: false, reusesTab: true)
            }, openDiff: { [weak services] text, link, file, view in
                guard let services, let pane = view.flatMap(opener.source(containing:)) ?? services.windows.active?.focusedPane else { return false }
                // Its tab is named `repo#N` (the folder's last part).
                services.viewers.diffPages.open(chatPatch: DiffChatPatch(text: text, file: file, folder: "/" + link.reference), in: pane, focus: true)
                return true
            })
            let page = PageWebView(descriptor: .github, routes: [PageRoute(prefix: GitHubPageProvider.namespace, provider: provider)], route: route)
            provider.anchor = { [weak page] in page }
            provider.onShown = { [weak services] url, content in (services?.pages.provider(.github) as? WebPageTab)?.onShown?(url, content) }
            return page
        }
        services.pages.register(tab)
        return tab
    }

    /// Opens `url` in the GitHub page when it is a pull request link the native page shows
    /// (``GitHubLink``), the switch is on and the link rule sends it to a cmux tab; nil leaves it to
    /// its web page. `source`: the chat's pane.
    static func openGitHub(_ url: URL, from source: PaneController, services: AppServices) -> Bool? {
        guard GitHubViewerTunables.nativePullRequests.value, let link = GitHubLink(url),
              LinkRouter.shared.target(for: url) == .cmuxBrowser, LinkRouter.shared.routing().browserEnabled,
              source.daemon.supports(DaemonCapability.pageTabs.rawValue), case .connected = source.daemon.store.connectionState else { return nil }
        if link.files {
            // A pull request's Files tab (Session Info's View diff): its diff beside the chat, else that web page.
            GitHubPageProvider.openFiles(link, openDiff: { [weak source, weak services] text in
                guard let source, let services else { return }
                services.viewers.diffPages.open(chatPatch: DiffChatPatch(text: text, folder: "/" + link.reference), in: source, focus: true)
            }, openWeb: { [weak source, weak services] url in
                guard let source, let services else { return }
                _ = services.linkOpener.openWeb(url, from: source, background: false, reusesTab: true)
            })
            return true
        }
        let tab = registerGitHub(services)
        // The workspace's GitHub tab, wherever it is: selected and moved to this link, no new page.
        for pane in source.workspace?.panes.values.map({ $0 }) ?? [source] {
            let keys = services.pages.tabIDs(in: pane.paneKey) + pane.pane.tabs.compactMap { services.pages.storeKey(of: $0.id) }
            guard let key = keys.first(where: { LocalPageTab.page(of: $0) == .github }) else { continue }
            tab.navigate(key, to: link.route)
            guard let id = services.pages.stripID(showing: key, in: pane) else { continue }
            pane.select(id)
            // As the web tab's open: in another pane, its close, emptying that pane, gives the focus back to the chat.
            if pane !== source, let content = source.workspace, let shown = pane.pane.tabs.first(where: { $0.id == id.rawValue }) {
                services.linkOpener.returnFocus(of: shown.surface, to: source.layoutPaneID, in: content)
            }
            pane.focusContent()
            return true
        }
        return services.linkOpener.open(from: source, kind: .browser) { [weak tab] pane, placed in
            guard let tab, let window = services.windowController(showing: pane) else { return false }
            let key = LocalPageTab.makeKey(.github), opener = pane === source && placed == nil && !HomeDockOpens.opensBeside(pane.pane, services: services) ? pane.selectedTab : nil
            tab.restore(link.route, for: key)
            // As for its web tab: the chat is its opener in the chat's pane; in another pane its close, emptying it, focuses the chat.
            let adopt = opener.flatMap { o in NewTabSlot.placing(after: o, services: services) { [weak services] in services?.cache.pageRequests.openers.adopt($0, opener: o.surface) } }
            let made = placed ?? adopt ?? HomeDockOpens.placing(pane.pane, services: services, focus: true, then: nil)
            var created = made
            if pane !== source || placed != nil { created = { @MainActor [weak source] surface in
                if let source, let content = source.workspace { services.linkOpener.returnFocus(of: surface, to: source.layoutPaneID, in: content) }
                made?(surface)
            } }
            return services.pages.openStoreTab(.github, in: pane, window: window, focus: placed == nil, key: key, created: created,
                                               requiresSurface: placed != nil) != nil
        }
    }
}

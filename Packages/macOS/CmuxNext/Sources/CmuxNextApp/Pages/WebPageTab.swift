import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDiff
import CmuxNextGitHubViewer
import CmuxNextIcons
import CmuxNextLayout
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
        let tab = WebPageTab(.github, symbol: "arrow.triangle.pull", icon: .gitPullrequest, title: GitHubPageProvider.title) { [weak services, checks = GitHubChecksCache()] _, route in
            guard let services else { return nil }
            let opener = services.linkOpener
            let provider = GitHubPageProvider(diffReader: { await AgentChatPullRequestReader().diff(url: $0) }, localDiff: GitHubLocalDiff { [git = services.agentGit.local] in try? await git.read("git.diff", params: $0) }, checks: checks, openWeb: { url, view in
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
        LinkRouter.shared.gitHubPage = { GitHubLink.clickOpensPage($0, routing: LinkRouter.shared.routing()) }
        LinkRouter.shared.openGitHubPage = { [weak services] url, source in services.flatMap { s in s.linkOpener.source(tab: source).flatMap { openGitHub(url, from: $0, services: s, explicit: true) } } ?? false }
        services.pages.register(tab)
        return tab
    }

    /// Opens `url` in the GitHub page when ``GitHubLink/page(for:routing:explicit:native:)`` takes it (`explicit`: a chat link
    /// menu's row, whatever `browser.openPullRequestsInGitHubPage`); nil leaves it to its web page. `source`: the chat's pane.
    static func openGitHub(_ url: URL, from source: PaneController, services: AppServices, explicit: Bool = false) -> Bool? {
        guard let link = GitHubLink.page(for: url, routing: LinkRouter.shared.routing(), explicit: explicit), source.daemon.supports(DaemonCapability.pageTabs.rawValue), case .connected = source.daemon.store.connectionState else { return nil }
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
        // A new split gets the page in one daemon commit (``gitHubSplit``); a pane on the right, a column or an older daemon go through `make`.
        let split = gitHubSplit(tab, route: link.route, returningTo: source, services: services)
        return services.linkOpener.open(from: source, kind: .browser, split: split) { [weak tab] pane, placed in
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

/// The GitHub page opened straight in a new split (https://github.com/manaflow-ai/cmux/issues/38184):
/// one `new-conversation-tab {page, split}` (`conversation-tab-split-v1`), the split and the page's
/// stand-in tab shown in the click's turn with the chain's even sizing, as a web link's split is
/// (``LinkOpener/browserSplit(_:profile:returningTo:)``). It used to be made hidden in the chat's pane
/// and moved to a new split once the store listed it, so the split played its opening and then the
/// tab moved into it: two animations for one click.
extension WebPageTab {
    /// The ``LinkOpener/SplitMake`` of a GitHub page tab on `route`. Nil (the open makes and moves) for a
    /// daemon without the capability, a pane with no room for a split, a pinned dock that is not Home's
    /// lone dock, or a script's open that may not change the view.
    static func gitHubSplit(_ tab: WebPageTab, route: String, returningTo source: PaneController,
                            services: AppServices) -> LinkOpener.SplitMake {
        { [weak tab, weak source, weak services] pane, direction, finished in
            let daemon = pane.daemon, store = daemon.store
            // Home's dock alone gets its column in the same commit, as a new chat's does (NewChatPlacement).
            let besideDock = direction == .right && daemon.supports(DaemonCapability.pinnedDockAlone.rawValue) && store.isLonePinnedDock(pane.pane.handle)
            guard let tab, let services, daemon.supports(DaemonCapability.conversationTabSplit.rawValue),
                  daemon.supports(DaemonCapability.splitClientKeys.rawValue), ActionRunScope.viewChangeAllowed(),
                  let window = services.windowController(showing: pane),
                  besideDock || !pane.isPinnedDockPane && { if case .split = services.splitRoom(for: pane.pane, edge: direction == .right ? .right : .bottom) { true } else { false } }()
            else { return nil }
            let key = LocalPageTab.makeKey(.github)
            tab.restore(route, for: key)
            let layout = pane.isPinnedDockPane ? nil : pane.workspace?.layoutModel // beside Home's dock it is a column: no even sizing
            let sizing = layout.map { $0.showSplitSizing($0.splitSizingChanges(splitting: pane.layoutPaneID, axis: direction == .right ? .horizontal : .vertical)) }
            let intent = pane.workspace?.beginFocusIntent()
            // A refusal before the request (nothing shown) is the caller's: `finished` runs only for a split that showed.
            var started = false
            let opened = services.pages.openStoreTab(.github, in: pane, window: window, focus: false, key: key, created: { [weak pane] surface in
                if let sizing { layout?.commitSplitSizing(sizing) }
                // As for a web link's split: the page takes the focus, and its close, emptying its pane, gives it back to the chat.
                if let source, let content = source.workspace { services.linkOpener.returnFocus(of: surface, to: source.layoutPaneID, in: content) }
                pane?.workspace?.expectFocus(on: surface, generation: intent)
                // The reply can come before the daemon's pane: the open's turn ends once the store lists the tab,
                // so the next open beside this pane never aims at the provisional pane (BrowserTabSplitCommand).
                services.registry.track(Task { @MainActor in
                    finished(await BrowserTabSplitCommand.listed(surface, in: store) ? surface : nil)
                    return nil
                })
            }, failed: { _ in
                guard started else { return }
                if let sizing { layout?.cancelSplitSizing(sizing) }
                finished(nil)
            }, requiresSurface: true, split: direction) != nil
            started = opened
            if opened {
                pane.workspace?.applyCurrent() // the split draws in the click's frame
            } else if let sizing {
                layout?.cancelSplitSizing(sizing)
            }
            return opened
        }
    }
}

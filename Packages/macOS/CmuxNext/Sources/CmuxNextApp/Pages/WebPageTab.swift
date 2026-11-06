import AppKit
import CmuxNextActions
import CmuxNextGitHubViewer
import CmuxNextIcons
import CmuxNextPages

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
    private let make: (String) -> NSView?
    private var pages: [String: NSView] = [:]

    convenience init(_ page: InternalPageID, symbol: String, icon: IconName? = nil, title: String, make: @escaping () -> PageWebView?) {
        self.init(page, symbol: symbol, icon: icon, title: title, view: { _ in make() })
    }

    /// A page whose tabs are native views made per tab `key` (the native New Tab page).
    init(_ page: InternalPageID, symbol: String, icon: IconName? = nil, title: String, view make: @escaping (String) -> NSView?) {
        self.page = page
        self.symbol = symbol
        self.icon = icon
        self.title = title
        self.make = make
    }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let view = make(key) else { return NSView() }
        pages[key] = view
        return view
    }

    func tabClosed(_ key: String) { (pages.removeValue(forKey: key) as? PageWebView)?.close() }
}

extension InternalPageID {
    /// #36101's GitHub page, retired (Leo, 2026-11-05: "let's undo this opening github with this kind
    /// of rendering"): only its saved tabs still name it (``RetiredGitHubPageTab``).
    static let github = InternalPageID(rawValue: "github")
}

/// A GitHub page tab a session restores or Reopen Closed brings back, from before the page was
/// retired: shown, it opens its pull request's github.com page in a browser tab right after it in
/// its pane and closes, so no saved tab is left blank. A tab with no pull request just closes.
@MainActor
final class RetiredGitHubPageTab: InternalPageProvider {
    let page = InternalPageID.github
    let symbol = "arrow.triangle.pull"
    /// A host name, not copy: shown only until the tab gives way to its web page.
    let title = "github.com"
    private weak var services: AppServices?
    /// Each tab's pull request, from its saved route (`#/pull?url=<address>`).
    private var urls: [String: URL] = [:]

    private init(services: AppServices) { self.services = services }

    /// Registered at launch, so a restored GitHub tab has an owner.
    static func register(_ services: AppServices) {
        guard services.pages.provider(.github) == nil else { return }
        services.pages.register(RetiredGitHubPageTab(services: services))
    }

    func restore(_ route: String, for key: String) { urls[key] = GitHubLink(route: route)?.url }
    func title(forRoute route: String) -> String? { GitHubLink(route: route)?.reference }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let url = urls.removeValue(forKey: key)
        // task-owner: one swap per shown tab, after the store has tracked it; ends when its web tab is asked for and it closes.
        Task { @MainActor [weak services] in
            guard let services, let id = services.pages.storeTab(forKey: key) else { return }
            if let url, let pane = services.linkOpener.source(tab: id),
               let tab = pane.pane.tabs.first(where: { $0.id == id }) {
                pane.newBrowserTab(url: url, opener: tab.surface)
            }
            services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: id)))
        }
        return NSView()
    }

    func tabClosed(_ key: String) { urls[key] = nil }
}

import AppKit
import CmuxNextActions
import CmuxNextHibernation
import CmuxNextIcons
import CmuxNextPages

extension InternalPageID {
    /// The Cloud page tab (`cmux-page://cmux.cloud/`): machines, snapshots, ports, files and plan.
    static let cloud = InternalPageID(rawValue: "cloud")
}

/// Owns the Cloud page as a pane tab (plans/cmux-next/cloud-app.md L7): the React Cloud page
/// (``PageFactory/cloudWebPage(_:route:)``) in an internal page tab, one per window. `palette.openCloudPane`
/// (the palette, the Window menu, `cmux pane open-cloud-as` and MCP) shows it.
@MainActor
final class CloudPageService: InternalPageProvider {
    /// A tab's page with its `cmux.cloud.` provider.
    typealias MadePage = (page: PageWebView, provider: CloudPageProvider)

    private weak var services: AppServices?
    /// Each tab's page while it lives (the provider for its keep reasons).
    private var pages: [String: MadePage] = [:]
    /// The place each discarded Cloud tab showed, for the page its next show makes.
    private let discardedRoutes = DiscardedPageRoutes()
    /// Makes a tab's page on a route (default: ``PageFactory/cloudWebPage(_:route:)``; tests pass
    /// their own engine).
    private let makePage: (String?) -> MadePage?

    init(services: AppServices, makePage: ((String?) -> MadePage?)? = nil) {
        self.services = services
        self.makePage = makePage ?? { [weak services] route in
            guard let services else { return nil }
            let factory = PageFactory(services: services)
            let cloud = factory.cloudPageProvider()
            return factory.cloudWebPage(cloud, route: route).map { (page: $0, provider: cloud) }
        }
    }

    /// Selects the active window's Cloud tab, or opens one after the focused pane's selected tab,
    /// showing `route` (a URL fragment such as `/get`, the storefront) when given.
    func open(focus: Bool, route: String? = nil) throws {
        guard let services, let window = services.windows.active,
              let view = services.pages.show(.cloud, in: window, focus: focus) else {
            throw ActionFailure(message: RefusalStrings.noWindowOpen)
        }
        if let route, let page = view.content as? PageWebView { page.open(route: route) }
    }

    var page: InternalPageID { .cloud }
    var title: String { String(localized: "cloud.page.title", defaultValue: "Cloud", table: "Cloud", bundle: .module) }
    var symbol: String { "cloud" }
    var icon: IconName? { .cloud }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        // A rebuilt page opens on the place its discarded one showed.
        guard let made = makePage(discardedRoutes.take(key)) else { return NSView() }
        pages[key] = made
        return made.page
    }

    func tabClosed(_ key: String) {
        discardedRoutes.forget(key)
        close(key)
    }

    // MARK: Discard (`memoryDiscardInternalPages`, p07-memory-028)

    /// Ten minutes hidden, as a browser tab (Chrome's proactive_discarding_policy.cc): the page
    /// reads the machines again when it is made.
    func discardPolicy(for key: String) -> ContentDiscardPolicy { .standard }

    /// A create (or any change the person approved) that has not answered keeps the page: only it
    /// shows the result, and its watch stream turns the answer into the new machine's row.
    func keepReasons(for key: String) -> [CannotDiscardReason] {
        (pages[key]?.provider.confirmedCallsInFlight ?? 0) > 0 ? [.inProgress] : []
    }

    /// Its document scroll (the machine list), and the place the page shows now (the storefront's
    /// `/get`, or wherever its own links moved it).
    func saveViewState(for key: String, content: NSView) async -> ContentViewState {
        guard let page = content as? PageWebView else { return ContentViewState() }
        return await discardedRoutes.save(key, page: page)
    }

    /// The tab stays and its page goes, closed as at ``tabClosed(_:)``.
    func viewDiscarded(_ key: String) {
        if let page = pages[key]?.page { discardedRoutes.discarded(key, page: page) }
        close(key)
    }

    /// Ends tab `key`'s page: its routes, bridge, engine page and pool claim.
    private func close(_ key: String) {
        guard let page = pages.removeValue(forKey: key)?.page else { return }
        if let services { services.webUI.close(page) } else { page.close() }
    }
}

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
    /// The place each hidden Cloud tab's page showed when its discard read it.
    private var shownPlaces: [String: (version: Int, fragment: String?)] = [:]
    /// The place each discarded Cloud tab showed, for the page its next show makes.
    private var discardedRoutes: [String: String] = [:]
    /// The place each ``open(focus:route:)`` asked for, for the page of a tab with no page yet.
    private let opens = PageOpenRequests<String>()
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
              let view = opens.open(route, { services.pages.show(.cloud, in: window, focus: focus) }) else {
            throw ActionFailure(message: RefusalStrings.noWindowOpen)
        }
        // A shown page moves to the route; a tab with no page yet opens on it at its first show.
        if let route, view.isBuilt, let page = view.content as? PageWebView { page.open(route: route) }
    }

    var page: InternalPageID { .cloud }
    var title: String { String(localized: "cloud.page.title", defaultValue: "Cloud", table: "Cloud", bundle: .module) }
    var symbol: String { "cloud" }
    var icon: IconName? { .cloud }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        // A page opens on the place its tab's show asked for, a rebuilt one on the place its
        // discarded one showed.
        let asked = opens.take(for: key), discarded = discardedRoutes.removeValue(forKey: key)
        guard let made = makePage(asked ?? discarded) else { return NSView() }
        pages[key] = made
        return made.page
    }

    func tabClosed(_ key: String) {
        shownPlaces[key] = nil
        discardedRoutes[key] = nil
        opens.forget(key)
        close(key)
    }

    // MARK: Discard (`memoryDiscardInternalPages`)

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
        shownPlaces[key] = await page.readShownPlace()
        return ContentViewState(scroll: await page.documentScroll())
    }

    /// The tab stays and its page goes, closed as at ``tabClosed(_:)``.
    func viewDiscarded(_ key: String) {
        let read = shownPlaces.removeValue(forKey: key)
        if let page = pages[key]?.page { discardedRoutes[key] = page.discardedPlace(read: read) }
        close(key)
    }

    /// Ends tab `key`'s page: its routes, bridge, engine page and pool claim.
    private func close(_ key: String) {
        guard let page = pages.removeValue(forKey: key)?.page else { return }
        if let services { services.webUI.close(page) } else { page.close() }
    }
}

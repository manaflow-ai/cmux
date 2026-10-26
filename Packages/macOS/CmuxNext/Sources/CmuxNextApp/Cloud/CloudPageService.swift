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
/// (``PageFactory/cloudWebPage()``) in an internal page tab, one per window. `palette.openCloudPane`
/// (the palette, the Window menu, `cmux pane open-cloud-as` and MCP) shows it.
@MainActor
final class CloudPageService: InternalPageProvider {
    private weak var services: AppServices?
    /// Each tab's `cmux.cloud.` provider while its page lives, for its keep reasons.
    private var providers: [String: CloudPageProvider] = [:]

    init(services: AppServices) { self.services = services }

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
        guard let services else { return NSView() }
        let factory = PageFactory(services: services)
        let cloud = factory.cloudPageProvider()
        guard let page = factory.cloudWebPage(cloud) else { return NSView() }
        providers[key] = cloud
        return page
    }

    func tabClosed(_ key: String) { providers[key] = nil }

    // MARK: Discard (`memoryDiscardInternalPages`, p07-memory-028)

    /// Ten minutes hidden, as a browser tab (Chrome's proactive_discarding_policy.cc): the page
    /// reads the machines again when it is made.
    func discardPolicy(for key: String) -> ContentDiscardPolicy { .standard }

    /// A create (or any change the person approved) that has not answered keeps the page: only it
    /// shows the result, and its watch stream turns the answer into the new machine's row.
    func keepReasons(for key: String) -> [CannotDiscardReason] {
        (providers[key]?.confirmedCallsInFlight ?? 0) > 0 ? [.inProgress] : []
    }

    /// The route the page was asked to show (the storefront's `/get`), so the next page opens on it.
    func saveViewState(for key: String, content: NSView) async -> ContentViewState {
        guard let route = (content as? PageWebView)?.route else { return ContentViewState() }
        return ContentViewState(values: [Self.routeValue: route])
    }

    func restoreViewState(_ state: ContentViewState, for key: String, content: NSView) {
        guard let route = state.values[Self.routeValue], let page = content as? PageWebView else { return }
        page.open(route: route)
    }

    func viewDiscarded(_ key: String) { providers[key] = nil }

    static let routeValue = "route"
}

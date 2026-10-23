import AppKit
import CmuxNextActions
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
        guard let services, let page = PageFactory(services: services).cloudWebPage() else { return NSView() }
        return page
    }
}

import CmuxNextPages
import Foundation

/// Builds the app's React pages with their routes (its own type, not an `AppServices` member:
/// that type's line budget is frozen).
@MainActor
struct PageFactory {
    unowned let services: AppServices

    /// The React History page when Debug Settings `history.surface` is `web`, else nil (the
    /// Swift page). The tunable goes when the React page becomes the default (react-pages.md H3).
    func historyWebPage() -> PageWebView? {
        guard PageTunables.history.value == .web,
              let page = PageWebView(descriptor: .history, routes: pageRoutes(for: .history)) else { return nil }
        PageConnectionWatch(page: page, store: services.machines.local.store).start()
        return page
    }

    /// The Cloud app page (cmux.cloud) with the machine list layout from Debug Settings. Its
    /// namespace answers "not available yet" until the app supervisor (apps-v1) runs the Cloud app
    /// server; then the route goes to the supervisor relay.
    func cloudWebPage() -> PageWebView? {
        let native = AppPageNativeProvider(services: services, page: .cloud)
        let cloud = UnavailablePageProvider(code: "cmux.cloud.unsupported")
        native.forward = { op, params, context in try await cloud.call(op, params: params, context: context) }
        let routes = [PageRoute(prefix: "cmux.cloud.", provider: cloud), PageRoute(prefix: "cmux.app.", provider: native)]
        let page = PageWebView(descriptor: .cloud, routes: routes,
                               documentAttributes: ["cloud-machines-layout": PageTunables.cloudMachinesLayout.value.rawValue])
        native.anchor = { [weak page] in page }
        if let page { PageConnectionWatch(page: page, store: services.machines.local.store).start() }
        return page
    }

    /// The routes of `page`: its namespaces to the daemon relay, `cmux.app.` to the native ops
    /// (whose confirmed ops run on the namespace relay after the sheet).
    func pageRoutes(for page: PageDescriptor) -> [PageRoute] {
        let relay = DaemonPageRelay(services: services)
        let native = AppPageNativeProvider(services: services, page: page)
        native.forward = { op, params, context in try await relay.call(op, params: params, context: context) }
        return page.namespaces.map { PageRoute(prefix: $0, provider: relay) } + [PageRoute(prefix: "cmux.app.", provider: native)]
    }
}

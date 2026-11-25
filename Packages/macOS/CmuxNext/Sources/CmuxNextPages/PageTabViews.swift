package import AppKit

/// Native views, read capabilities and routes owned by the tabs of a single page.
@MainActor
package final class PageTabViews {
    private let make: (_ key: String, _ route: String?) -> NSView?
    private var pages: [String: NSView] = [:]
    private var localPages: [String: PageWebView] = [:] // pages bound to a capability in this app only
    /// What each tab of a routed page shows (its `#/...` route), so a restored or reopened tab shows it again.
    private var routes: [String: String] = [:]
    package init(make: @escaping (String, String?) -> NSView?) {
        self.make = make
    }

    package func bind(_ view: PageWebView?, to key: String, route: String) -> Bool {
        guard let view else { return false }
        localPages[key] = view
        routes[key] = route
        return true
    }

    package func view(for key: String) -> NSView {
        guard let view = localPages[key] ?? make(key, routes[key]) else { return NSView() }
        pages[key] = view
        return view
    }

    package func route(for key: String) -> String? { routes[key] }
    package func restore(_ route: String, for key: String) { routes[key] = route }

    /// Moves tab `key` to `route`: a route change in its page when it runs, else what it opens with.
    package func navigate(_ key: String, to route: String) {
        routes[key] = route
        (pages[key] as? PageWebView)?.open(route: route)
    }

    package func tabClosed(_ key: String) {
        (pages.removeValue(forKey: key) as? PageWebView)?.close()
        localPages[key] = nil
        routes[key] = nil
    }
}

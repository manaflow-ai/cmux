public import CmuxNextApps
public import CmuxNextPages
import Foundation

public extension PageDescriptor {
    /// An app's pane (webviews/src/pages/app-scene): the one scene its route names
    /// (`#/?app=<id>`), mounted through ``AppsPanelsPageProvider`` with `surface: pane`, and the
    /// mount's bundle images under `__appbundle/` and its scene's SF Symbols under `__appsymbol/`. It reaches nothing else. A click that only brings
    /// the window forward must not reach the app's own buttons.
    static let appScene = PageDescriptor(
        id: "cmux.app-scene", resource: "app-scene", namespaces: [AppsPanelsPageProvider.namespace],
        dynamicPrefixes: [AppsPanelsPageProvider.bundlePrefix, AppsPanelsPageProvider.symbolPrefix], acceptsFirstMouse: false)
}

/// Makes the pages app panes draw in (``PageDescriptor/appScene``) over the app supervisor's
/// client: each page gets its own ``AppsPanelsPageProvider``, which also serves the mount's bundle
/// images. Closing a page (``PageWebView/close()``) ends its mount.
///
/// ```swift
/// let page = AppScenePage(client: apps.client).make(app: "samples/github-prs")
/// ```
@MainActor
public struct AppScenePage {
    public let client: AppsClient

    public init(client: AppsClient) { self.client = client }

    /// The page for `app`'s pane, nil when the page's resources are missing (a build without the web bundles).
    public func make(app: String) -> PageWebView? {
        let panels = AppsPanelsPageProvider(client: client)
        panels.servesBundleImages = true
        return PageWebView(descriptor: .appScene, routes: [PageRoute(prefix: AppsPanelsPageProvider.namespace, provider: panels)],
                           route: Self.route(app: app), dynamicResources: panels)
    }

    /// `#/?app=<id>`, the id query-encoded.
    nonisolated static func route(app: String) -> String {
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "app", value: app)]
        return "#/?" + (query.percentEncodedQuery ?? "")
    }
}

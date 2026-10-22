import AppKit
import CmuxNextApps
import CmuxNextIcons
import CmuxNextPages

/// An app's web pane (`cmux.pane/1` with `web`) as an internal page tab, page id `app:<app id>`
/// (the same id as a scene pane, so the sidebar's app item opens either). The page runs on the
/// shared page host: a WebKit content process, the strict page CSP, files only from the entry's
/// folder in the app bundle, no native ops and no registry actions
/// (``PageDescriptor/appPage(id:resource:namespaces:)``).
@MainActor
final class AppWebPanePage: InternalPageProvider {
    let appID: String
    private weak var apps: AppsService?
    private var pages: [String: PageWebView] = [:]

    init(appID: String, apps: AppsService?) {
        self.appID = appID
        self.apps = apps
    }

    var page: InternalPageID { AppPanePage.pageID(appID) }
    var title: String { app?.manifest.name.resolved() ?? appID }
    var symbol: String {
        if case .symbol(let name)? = app?.manifest.icon { return name }
        return pane?.implementation.symbol ?? "app"
    }
    var icon: IconName? { symbol == "app" ? .appGeneric : nil }

    private var app: AppRecord? { apps?.client.app(appID) }
    private var pane: AppWebPane? {
        guard let app, case .web(let pane) = AppPaneRoute(app.manifest) else { return nil }
        return pane
    }

    /// Whether `app` has a web pane this Mac can serve (active, a bundle on disk, a safe entry).
    static func opens(_ app: AppRecord) -> Bool {
        guard app.isActive, case .web(let pane) = AppPaneRoute(app.manifest), let bundle = app.bundleDirectory else { return false }
        return pane.root(in: bundle) != nil && AppWebPane.pageHost(appID: app.id) != nil
    }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let app, let pane, let bundle = app.bundleDirectory, let root = pane.root(in: bundle),
              let host = AppWebPane.pageHost(appID: app.id),
              let descriptor = try? PageDescriptor.appPage(id: host, resource: "", namespaces: []),
              let view = PageWebView(descriptor: descriptor, root: root, routes: []) else { return NSView() }
        pages[key] = view
        return view
    }

    func tabClosed(_ key: String) {
        pages.removeValue(forKey: key)?.close()
    }
}

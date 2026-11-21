import AppKit
import CmuxNextAgentPane
import CmuxNextApps
import CmuxNextIcons
import CmuxNextPages

/// An app's own page (`cmux.pane/1`: a scene export, or a web page with `render: web`) as an
/// internal page tab: page id `app:<app id>`, one tab per window, each tab's view from
/// ``AppScenePage`` for scene panes or ``AppPaneViews`` for web panes. First-party apps open
/// this way from their sidebar label item.
@MainActor
final class AppPanePage: InternalPageProvider {
    let appID: String
    private unowned let apps: AppsService
    private var pages: [String: PageWebView] = [:]
    private lazy var views = AppPaneViews(client: apps.client)

    init(appID: String, apps: AppsService) {
        self.appID = appID
        self.apps = apps
    }

    static func pageID(_ appID: String) -> InternalPageID { InternalPageID(rawValue: "app:" + appID) }

    var page: InternalPageID { Self.pageID(appID) }
    var title: String { app?.manifest.name.resolved() ?? appID }
    var symbol: String {
        if case .symbol(let name)? = app?.manifest.icon { return name }
        return app?.manifest.scenePane?.symbol ?? app?.webPane?.symbol ?? "app"
    }
    /// The registry's generic app for an app with no symbol of its own.
    var icon: IconName? { symbol == "app" ? .appGeneric : nil }

    private var app: AppRecord? { apps.client.app(appID) }

    /// Whether this app has a page to open (installed, enabled, with a scene or web pane). A
    /// hidden app still opens on an explicit `app.open`; hiding removes only its sidebar, palette
    /// and menu presence (those callers check presence themselves).
    static func opens(_ app: AppRecord) -> Bool { app.isActive && (app.manifest.scenePane != nil || app.webPane != nil) }

    /// An app that no longer opens shows the failure row (the host refuses its mount); no page resources, an empty view.
    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let app else { return NSView() }
        if app.manifest.scenePane != nil {
            guard let page = AppScenePage(client: apps.client).make(app: appID) else { return NSView() }
            pages[key] = page
            return page
        }
        return views.makeView(app, key: key)
    }

    func tabClosed(_ key: String) {
        pages.removeValue(forKey: key)?.close()
        views.close(key)
    }
}

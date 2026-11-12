import AppKit
import CmuxNextAgentPane
import CmuxNextApps
import CmuxNextIcons
import CmuxNextPages

/// An app's own page (its `cmux.pane/1` implementation rendered from a scene
/// export; `contributes.paneKinds` in manifest v1) as an internal page tab:
/// page id `app:<app id>`, one tab per window, each the React app pane page
/// (``AppScenePage``; its mount ends with the tab). First-party apps open this
/// way from their sidebar label item (CodeRouter: below the App Store).
@MainActor
final class AppPanePage: InternalPageProvider {
    let appID: String
    private unowned let apps: AppsService
    private var pages: [String: PageWebView] = [:]

    init(appID: String, apps: AppsService) {
        self.appID = appID
        self.apps = apps
    }

    static func pageID(_ appID: String) -> InternalPageID { InternalPageID(rawValue: "app:" + appID) }

    var page: InternalPageID { Self.pageID(appID) }
    var title: String { app?.manifest.name.resolved() ?? appID }
    var symbol: String {
        if case .symbol(let name)? = app?.manifest.icon { return name }
        return app?.manifest.scenePane?.symbol ?? "app"
    }
    /// The registry's generic app for an app with no symbol of its own.
    var icon: IconName? { symbol == "app" ? .appGeneric : nil }

    private var app: AppRecord? { apps.client.app(appID) }

    /// Whether this app has a page to open (installed, enabled, with a scene pane). A hidden
    /// app still opens on an explicit `app.open`; hiding removes only its sidebar, palette and
    /// menu presence (those callers check presence themselves).
    static func opens(_ app: AppRecord) -> Bool { app.isActive && app.manifest.scenePane != nil }

    /// An app that no longer opens shows the failure row (the host refuses its mount); no page resources, an empty view.
    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let page = AppScenePage(client: apps.client).make(app: appID) else { return NSView() }
        pages[key] = page
        return page
    }

    func tabClosed(_ key: String) { pages.removeValue(forKey: key)?.close() }
}

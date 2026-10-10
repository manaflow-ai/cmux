import AppKit
import CmuxNextApps
import CmuxNextIcons

/// An app's own page (its `cmux.pane/1` implementation rendered from a scene
/// export; `contributes.paneKinds` in manifest v1) as an internal page tab:
/// page id `app:<app id>`, one tab per window, the app's scene mounted per
/// tab through the app supervisor (`apps-mount`). First-party apps open this
/// way from their sidebar label item (CodeRouter: below the App Store).
@MainActor
final class AppPanePage: InternalPageProvider {
    let appID: String
    private unowned let apps: AppsService
    private var mounts: [String: AppMount] = [:]

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

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let app, let pane = app.manifest.scenePane else { return NSView() }
        let mount = apps.client.mount(app.id, implementation: pane, surface: "pane")
        mounts[key] = mount
        return mount.makeView()
    }

    func tabClosed(_ key: String) {
        guard let mount = mounts.removeValue(forKey: key) else { return }
        apps.client.unmount(mount)
    }
}

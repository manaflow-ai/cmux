import AppKit
import CmuxNextApps
import CmuxNextIcons

/// An app's own page (its pane implementation, `contributes.paneKinds` in
/// manifest v1) as an internal page tab: page id `app:<app id>`, one tab per
/// window, the app's scene mounted per tab. First-party apps open this way
/// from their sidebar label item (CodeRouter: below the App Store).
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
        return pane?.symbol ?? "app"
    }
    /// The registry's generic app for an app with no symbol of its own.
    var icon: IconName? { symbol == "app" ? .appGeneric : nil }

    private var app: InstalledApp? { apps.registry.app(appID) }
    /// The app's first pane implementation.
    private var pane: AppContribution? { app?.manifest.contributes.of(.paneKind).first }

    /// Whether this app has a page to open (installed, visible, with a pane).
    static func opens(_ app: InstalledApp) -> Bool { app.isVisible && app.manifest.contributes.of(.paneKind).first?.export != nil }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let app, let pane else { return NSView() }
        let mount = apps.host.mount(app.manifest, directory: app.bundle.directory, contribution: pane, surface: "pane")
        mounts[key] = mount
        return mount.makeView()
    }

    func tabClosed(_ key: String) {
        guard let mount = mounts.removeValue(forKey: key) else { return }
        apps.host.unmount(mount)
    }
}

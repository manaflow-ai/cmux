public import AppKit
public import CmuxNextPages
import Foundation

/// The views of apps' own panes (`cmux.pane/1`), one per page tab: the app's scene mounted
/// through the supervisor (`apps-mount`), or its web page (`render: web`) on the shared page
/// host. The App's page provider only asks for a tab's view and says when the tab closed.
@MainActor
public final class AppPaneViews {
    private let client: AppsClient
    private var mounts: [String: AppMount] = [:]
    private var pages: [String: AppWebPaneHost] = [:]

    public init(client: AppsClient) {
        self.client = client
    }

    /// The pane `app` shows in tab `key`: its scene when it has one, else its web page.
    public func makeView(_ app: AppRecord, key: String) -> NSView {
        if let pane = app.manifest.scenePane {
            let mount = client.mount(app.id, implementation: pane, surface: "pane")
            mounts[key] = mount
            return mount.makeView()
        }
        guard let web = app.webPane, let host = AppWebPaneHost(app: app, page: web, client: client) else { return NSView() }
        pages[key] = host
        return host.view
    }

    /// Tab `key` closed: its mount ends, or its page closes (its bridge and its calls end).
    public func close(_ key: String) {
        pages.removeValue(forKey: key)?.close()
        if let mount = mounts.removeValue(forKey: key) { client.unmount(mount) }
    }

    /// The web page shown in tab `key`, if that tab shows one (tests and probes).
    public func webPage(_ key: String) -> PageWebView? { pages[key]?.view }
    /// How often the web page in tab `key` reloaded for a save of its app's files.
    public func webPageReloads(_ key: String) -> Int? { pages[key]?.reloads }
}

/// One open web pane: a ``PageWebView`` on the app's own origin (`cmux-page://<host>/`, where
/// `<host>` is the app id with `.` for `/`) that serves only the files under the root the daemon
/// named, with the strict page CSP (no network, no frames: an app id is never first party), in
/// its own WebKit content process, its calls going through ``AppWebPaneProvider``. A local
/// reload of the app's files (`apps-changed`, `local-reload`) reloads the page in place.
@MainActor
final class AppWebPaneHost {
    let view: PageWebView
    let provider: AppWebPaneProvider
    /// Reloads for saves of the app's files (``AppsTransportEvent/changed(revision:app:)``).
    private(set) var reloads = 0

    init?(app: AppRecord, page: AppWebPage, client: AppsClient, pageKey: String = UUID().uuidString.lowercased()) {
        let host = app.id.lowercased().replacingOccurrences(of: "/", with: ".")
        guard let package = app.bundleDirectory, let root = page.rootURL(in: package),
              let descriptor = try? PageDescriptor.appPage(id: host, resource: page.root, namespaces: [host + "."], entry: page.entry)
        else { return nil }
        let appID = app.id
        let provider = AppWebPaneProvider(appID: appID, pageKey: pageKey, prefix: host + ".") { [weak client] (message: String) async throws(AppsTransportError) -> AppJSON in
            guard let client else { throw AppsTransportError(message: "apps-page-call", connectionLost: true) }
            return try await client.pageCall(app: appID, page: pageKey, message: message)
        }
        // Chromium serves only the app's own bundled pages; an extension's root stays on WebKit.
        guard let view = PageWebView(descriptor: descriptor, root: root, routes: [PageRoute(prefix: host + ".", provider: provider)],
                                     options: PageEngineOptions(requiresWebKit: .notServedByChromium)) else { return nil }
        self.view = view
        self.provider = provider
        client.observeEvents(owner: self) { [weak self] event in
            guard case .changed(_, let changed?) = event, changed == appID else { return }
            guard let self else { return }
            self.reloads += 1
            self.view.reload()
        }
    }

    func close() { view.close() }
}

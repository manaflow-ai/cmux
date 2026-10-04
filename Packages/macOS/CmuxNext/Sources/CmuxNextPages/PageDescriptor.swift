public import Foundation

/// One React page the app hosts (plans/cmux-next/react-pages.md 1, pane-protocol.md "Pages"):
/// its id (also the origin host, `cmux-page://<id>`), its bundled resource directory, and what it
/// may call. One origin per page id, so a page never shares an origin with another page.
public nonisolated struct PageDescriptor: Sendable, Hashable {
    public static let scheme = "cmux-page"

    /// `cmux.history`, `cmux.apps`, `cmux.settings`.
    public let id: String
    /// The directory under `Resources/pages/` that holds the page's `index.html`.
    public let resource: String
    /// Op and stream name prefixes the page may use (`cmux.history.`).
    public let namespaces: [String]
    /// Native UI ops the page may call (`cmux.app.action.run`).
    public let nativeOps: Set<String>
    /// Ops never allowed from this page even inside its namespaces (`cmux.settings.domains.publish`).
    public let denied: Set<String>
    /// Registry actions the page may run through `cmux.app.action.run` (`history.open`). A page
    /// runs nothing else, so a page bug cannot reach unrelated app actions.
    public let actions: Set<String>
    /// The dispatcher commands this page takes on `cmux.page.command` (default: every page command).
    public let commands: Set<String>
    /// Namespace ops the page may only run through `cmux.app.action.run {action: <op>, args}`: the
    /// host shows the native confirmation of that kind, then runs the op as the user's own
    /// (deleting data, money, publishing, signing in). The page never calls them directly.
    public let confirmedOps: [String: PageConfirmation.Kind]
    /// The page's Content Security Policy (``PageCSP``); strict unless a first-party page widens it.
    public let csp: PageCSP
    /// The file `cmux-page://<id>/` serves (default `index.html`): a page whose root is a shared
    /// build (the diff viewer in the one webviews-app build) names its own entry html.
    public let entry: String
    /// First path components the page instance's ``PageDynamicResourceSource`` answers
    /// (`__patch`); the scheme handler never serves a static file under one.
    public let dynamicPrefixes: Set<String>

    public init(id: String, resource: String, namespaces: [String], nativeOps: Set<String> = [], denied: Set<String> = [],
                actions: Set<String> = [], commands: Set<String> = PageNativeOp.commands,
                confirmedOps: [String: PageConfirmation.Kind] = [:], csp: PageCSP = .strict, entry: String = "index.html",
                dynamicPrefixes: Set<String> = []) {
        self.id = id
        self.resource = resource
        self.namespaces = namespaces
        self.nativeOps = nativeOps
        self.denied = denied.union(confirmedOps.keys)
        self.actions = actions
        self.commands = commands
        self.confirmedOps = confirmedOps
        // Only a first-party page may widen its policy (PageID); any other id gets the strict one.
        self.csp = PageID.isFirstParty(id) ? csp : .strict
        // One file name inside the root, never a path.
        self.entry = entry.isEmpty || entry.contains("/") || entry.hasPrefix(".") ? "index.html" : entry
        self.dynamicPrefixes = dynamicPrefixes
    }

    /// Whether the page may call `op` (or subscribe to the stream `op`).
    public func admits(_ op: String) -> Bool {
        guard !denied.contains(op) else { return false }
        return nativeOps.contains(op) || namespaces.contains { op.hasPrefix($0) && op.count > $0.count }
    }

    /// `cmux-page://<id>`.
    public var origin: String { "\(Self.scheme)://\(id)" }

    /// The page URL, with `route` as the fragment (`#/settings/appearance?focus=<key>`).
    public func url(route: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = id
        components.path = "/"
        if let route, !route.isEmpty { components.fragment = route.hasPrefix("#") ? String(route.dropFirst()) : route }
        return components.url ?? URL(fileURLWithPath: "/")
    }

    /// Whether `url` is a document of this page (its own origin).
    public func owns(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == Self.scheme && url.host?.lowercased() == id.lowercased()
    }
}

/// The native UI ops every page shares (react-pages.md 1.3). The host serves them; a page lists
/// the ones it uses in ``PageDescriptor/nativeOps``.
public nonisolated struct PageNativeOp {
    public nonisolated init() {}
    /// Runs a registry action in the app with origin `user`: `{action, args}`.
    public static let actionRun = "cmux.app.action.run"
    /// Writes text to the pasteboard: `{text}`.
    public static let clipboardWrite = "cmux.app.clipboard.write"
    /// Stream every page may subscribe to: `{command, text?}` from the app's key dispatcher
    /// (`find`, `focusSearch`, `back`, `forward`, `reset`). The page never reads chords itself.
    public static let pageCommand = "cmux.page.command"
    /// Built in for every page (DESKTOP-FEEL, R139): a double-click on a title bar the page draws
    /// (`data-titlebar`) runs the window's title bar action (System Settings: zoom or minimize).
    public static let titleBarDoubleClick = "cmux.app.window.title_bar_double_click"
    /// Stream every page may subscribe to: `{connected}`, the page's owner link (the daemon). The
    /// current state arrives as the first event.
    public static let pageConnection = "cmux.page.connection"
    /// The page commands the dispatcher sends (the Settings lead's page pattern).
    public static let commands: Set<String> = ["find", "focusSearch", "back", "forward", "reset"]
}

public extension PageDescriptor {
    /// The Cloud app page (`cmux/cloud`, plans/cmux-next/cloud-app.md L7; React page by the Cloud
    /// lead). Deleting, publishing, firewall changes, billing, sign-in/out and connect run only
    /// through the native confirmation.
    static let cloud = PageDescriptor(
        id: "cmux.cloud", resource: "cloud", namespaces: ["cmux.cloud."],
        nativeOps: [PageNativeOp.actionRun, PageNativeOp.clipboardWrite],
        confirmedOps: [
            "cmux.cloud.machine.delete": .delete, "cmux.cloud.snapshot.delete": .delete,
            "cmux.cloud.publication.delete": .delete, "cmux.cloud.firewall.delete": .delete,
            "cmux.cloud.publication.create": .custom, "cmux.cloud.firewall.create": .custom,
            "cmux.cloud.billing.open": .custom, "cmux.cloud.auth.sign_in": .custom,
            "cmux.cloud.auth.sign_out": .custom, "cmux.cloud.machine.connect": .custom,
        ])

    /// The Settings page (R82: the only Settings UI). Its `cmux.settings.` ops and the native
    /// preview and sound ops share the namespace; the page may run only the two actions it links to.
    static let settings = PageDescriptor(
        id: "cmux.settings", resource: "settings", namespaces: ["cmux.settings."],
        nativeOps: [PageNativeOp.actionRun],
        actions: ["palette.openCmuxSettingsFile", "openSettings", "browserProfile.new", "browserProfile.rename",
                  "browserProfile.setColor", "browserProfile.clearColor", "browserProfile.setIcon", "browserProfile.clearIcon",
                  "browserProfile.manageExtensions", "browserProfile.delete"])

    /// The History page (react-pages.md 2).
    static let history = PageDescriptor(
        id: "cmux.history", resource: "history", namespaces: ["cmux.history."],
        nativeOps: [PageNativeOp.actionRun, PageNativeOp.clipboardWrite], actions: ["history.open"])
}

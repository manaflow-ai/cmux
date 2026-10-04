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

    public init(id: String, resource: String, namespaces: [String], nativeOps: Set<String> = [], denied: Set<String> = [],
                actions: Set<String> = []) {
        self.id = id
        self.resource = resource
        self.namespaces = namespaces
        self.nativeOps = nativeOps
        self.denied = denied
        self.actions = actions
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
public nonisolated enum PageNativeOp {
    /// Runs a registry action in the app with origin `user`: `{action, args}`.
    public static let actionRun = "cmux.app.action.run"
    /// Writes text to the pasteboard: `{text}`.
    public static let clipboardWrite = "cmux.app.clipboard.write"
    /// Stream every page may subscribe to: `{command, text?}` from the app's key dispatcher
    /// (`find`, `focusSearch`, `back`, `forward`, `reset`). The page never reads chords itself.
    public static let pageCommand = "cmux.page.command"
    /// Stream every page may subscribe to: `{connected}`, the page's owner link (the daemon). The
    /// current state arrives as the first event.
    public static let pageConnection = "cmux.page.connection"
    /// The page commands the dispatcher sends (the Settings lead's page pattern).
    public static let commands: Set<String> = ["find", "focusSearch", "back", "forward", "reset"]
}

public extension PageDescriptor {
    /// The History page (react-pages.md 2).
    static let history = PageDescriptor(
        id: "cmux.history", resource: "history", namespaces: ["cmux.history."],
        nativeOps: [PageNativeOp.actionRun, PageNativeOp.clipboardWrite], actions: ["history.open"])
}

public import Foundation

/// One web pane (`render: web`) the daemon lets this client host for an app (`web_pages` of
/// its `apps-list` record). The daemon decided everything about it (cmux-app-manifest
/// `web_pages`): the file root inside the app's package, never outside it, and the entry file
/// inside that root. The client serves only that root's files on the page's own origin.
public nonisolated struct AppWebPage: Sendable, Hashable {
    /// The interface the page implements (`cmux.pane/1`).
    public var interface: String
    /// The file root, relative to the package (`web`).
    public var root: String
    /// The entry file, relative to the root (`index.html`).
    public var entry: String
    public var symbol: String?

    public init(interface: String, root: String, entry: String, symbol: String? = nil) {
        self.interface = interface
        self.root = root
        self.entry = entry
        self.symbol = symbol
    }

    init?(json: AppJSON) {
        guard let interface = json["interface"]?.stringValue, let root = json["root"]?.stringValue,
              let entry = json["entry"]?.stringValue else { return nil }
        self.init(interface: interface, root: root, entry: entry, symbol: json["symbol"]?.stringValue)
    }

    /// The page's file root inside `package`, or nil when the root would leave it (the daemon
    /// never lists such a page; this holds the rule on the client too).
    public func rootURL(in package: URL) -> URL? {
        let parts = root.split(separator: "/").map(String.init)
        guard !root.hasPrefix("/"), !parts.contains(where: { $0 == ".." || $0 == "." || $0.contains("\\") }) else { return nil }
        let base = package.standardizedFileURL.resolvingSymlinksInPath()
        let url = parts.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }.standardizedFileURL
        return url.path == base.path || url.path.hasPrefix(base.path + "/") ? url : nil
    }
}

public extension AppRecord {
    /// The app's own pane as a web page (`cmux.pane/1` with `web`), if the daemon hosts one.
    var webPane: AppWebPage? { webPages.first { $0.interface == AppImplementation.pane } }
}

public import Foundation
import UniformTypeIdentifiers

/// A custom pane an app renders from its own web page (plans/cmux-next/
/// custom-panes-DESIGN.md section 2): `implements["cmux.pane/1"].web`, served
/// from `runtime.web.root` of the app's package under `cmux-app://<namespace>/`.
///
/// Pure: where files come from, which URLs are the pane's own and the headers
/// each answer carries. The view, scheme handler and bridge use it; tests read
/// it without a web view.
public nonisolated struct AppWebPane: Sendable, Hashable {
    public static let scheme = "cmux-app"

    /// The host's policy: only the pane's own files, no plugin, frame, form
    /// target or base change. A manifest `runtime.web.csp` is sent as a second
    /// policy, and the browser enforces both, so it can only narrow this one.
    public static let hostCSP = [
        "default-src 'self'", "script-src 'self'", "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data: blob:", "font-src 'self' data:", "connect-src 'self'",
        "media-src 'self' blob:", "frame-src 'none'", "worker-src 'self' blob:",
        "object-src 'none'", "base-uri 'none'", "form-action 'none'",
    ].joined(separator: "; ")

    public let appID: String
    /// `app_namespace(id)`: `-` as `_` and the `/` as `.` (`local.workspace_board`).
    public let host: String
    /// The package folder the pane may read (`<bundle>/<runtime.web.root>`).
    public let root: URL
    /// The page's path inside `root` (`index.html`).
    public let entry: String
    public let csp: String?

    /// The web pane of `manifest` in `bundle`, or nil when it has none, or its
    /// root or page leaves the package or the page is outside the root.
    public init?(manifest: AppManifest, bundle: URL) {
        guard let pane = manifest.webPane, let page = pane.web,
              let rootPath = Self.relative(manifest.webRoot ?? ""), let pagePath = Self.relative(page),
              !rootPath.isEmpty, pagePath.starts(with: rootPath), pagePath.count > rootPath.count
        else { return nil }
        let base = bundle.standardizedFileURL.resolvingSymlinksInPath()
        let trimmedCSP = manifest.webCSP?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let webCSP: String? = trimmedCSP.isEmpty ? nil : trimmedCSP
        // The root itself may be a symlink: the folder it resolves to must stay in the package.
        let resolvedRoot = rootPath.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
            .standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedRoot.path.hasPrefix(base.path + "/"), webCSP.map(Self.cspAllowed) ?? true else { return nil }
        appID = manifest.id
        // app-platform.md 18's one id mapping (cmux-app-manifest `app_namespace`).
        let id = manifest.id.lowercased().replacingOccurrences(of: "-", with: "_")
        host = id.firstIndex(of: "/").map { id.replacingCharacters(in: $0...$0, with: ".") } ?? id
        root = resolvedRoot
        entry = pagePath.dropFirst(rootPath.count).joined(separator: "/")
        csp = webCSP
    }

    /// Directives a manifest policy may use, the daemon's list (cmux-app-manifest
    /// rules.rs `CSP_DIRECTIVES`): sent beside ``hostCSP``, fetch directives only
    /// narrow it, while `report-uri`, `report-to` or `navigate-to` could name a URL
    /// the page's data is sent to.
    static let cspDirectives: Set<String> = [
        "default-src", "script-src", "script-src-elem", "script-src-attr", "style-src",
        "style-src-elem", "style-src-attr", "img-src", "font-src", "connect-src", "media-src",
        "object-src", "frame-src", "child-src", "worker-src", "manifest-src", "base-uri",
        "form-action", "sandbox",
    ]

    /// Whether every directive of `csp` (`;` and `,` separated) is in ``cspDirectives``.
    static func cspAllowed(_ csp: String) -> Bool {
        csp.split(whereSeparator: { $0 == ";" || $0 == "," }).allSatisfy { directive in
            guard let name = directive.split(whereSeparator: \.isWhitespace).first else { return true }
            return cspDirectives.contains(name.lowercased())
        }
    }

    /// The page to load: `cmux-app://<host>/<entry>`.
    public var entryURL: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = host
        components.path = "/" + entry
        return components.url ?? URL(fileURLWithPath: "/")
    }

    /// Whether `url` is one of the pane's own (its scheme and host); every
    /// other navigation is refused and the message handler answers nobody else.
    public func isOwn(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == Self.scheme && url?.host?.lowercased() == host
    }

    /// The file `url` names inside `root`, or nil for another origin, an
    /// escaping or hidden path, or a path through a symlink out of `root`.
    public func file(for url: URL) -> URL? {
        guard isOwn(url) else { return nil }
        var parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.isEmpty { parts = [entry] }
        guard !parts.contains(where: { $0 == ".." || $0 == "." || $0.hasPrefix(".") }) else { return nil }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let file = parts.reduce(base) { $0.appendingPathComponent($1) }.standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(base.path + "/") else { return nil }
        return file
    }

    /// The headers of one answer: its type, both policies, no sniffing, no caching (so a
    /// saved file shows on the next reload) and no referrer.
    public func headers(for file: URL, length: Int) -> [String: String] {
        var headers = [
            "Content-Type": Self.mimeType(file.pathExtension),
            "Content-Length": String(length),
            "Content-Security-Policy": Self.hostCSP,
            "X-Content-Type-Options": "nosniff",
            "Cache-Control": "no-store",
            "Referrer-Policy": "no-referrer",
        ]
        // Two policies in one header (comma-separated) are both enforced.
        if let csp { headers["Content-Security-Policy"] = Self.hostCSP + ", " + csp }
        return headers
    }

    static func mimeType(_ pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html", "htm": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json; charset=utf-8"
        case "svg": "image/svg+xml"
        default: UTType(filenameExtension: pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    /// The parts of a package-relative path, or nil when it is absolute or has
    /// a `.`/`..` part. `""` and `"/"` are the package root (no parts).
    static func relative(_ path: String) -> [String]? {
        guard !path.hasPrefix("/"), !path.contains("\\") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return parts
    }
}

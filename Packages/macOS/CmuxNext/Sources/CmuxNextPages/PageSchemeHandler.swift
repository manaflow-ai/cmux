import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves bundled pages under `cmux-page://<page id>/` (one origin per page). Only GET requests
/// for files inside the page's own resource directory are answered; another host, an escaping
/// path or a missing file fails the request. `/` is the page's `index.html`. Every response
/// carries the page's CSP (``PageDescriptor/csp``, strict unless a first-party page widens it)
/// and `nosniff`.
///
/// A path whose first component is one of the descriptor's ``PageDescriptor/dynamicPrefixes``
/// goes to the page instance's ``PageDynamicResourceSource`` first and only: its answer, or a
/// 404 with the same headers. The same containment rules apply (no `.` or `..` components).
///
/// Absorbed from the Settings lead's `SettingsPageSchemeHandler` (branch
/// feat-cmux-next-settings-react), generalized to every page.
///
/// A pooled host (``PageHostPool``) has one handler for every first-party page: it resolves each
/// request's host (``PageServedHosts``) and answers with that page's own CSP; any other host fails.
final class PageSchemeHandler: NSObject, WKURLSchemeHandler {
    /// The strict policy every page starts with (``PageCSP/strict``).
    nonisolated static var contentSecurityPolicy: String { PageCSP.strict.header }

    /// Where a request goes.
    nonisolated enum Route: Equatable {
        case file(URL)
        case dynamic(PageResourceRequest)
    }

    /// What a request is answered with: a response and its body, or nil to fail the task.
    nonisolated struct Reply {
        let response: HTTPURLResponse
        let body: Data
    }

    /// What one host serves: its descriptor (origin, CSP, entry, dynamic prefixes), its file root,
    /// and the source of its dynamic prefixes (held weakly; the page view keeps it alive).
    struct Served {
        let page: PageDescriptor
        let root: URL
        weak var dynamicSource: (any PageDynamicResourceSource)?
    }

    /// The host (lowercased) to what it serves; nil fails the request.
    private let resolve: (String) -> Served?
    /// Tasks started and not yet answered or stopped; a stopped task must not be answered.
    private var active: Set<ObjectIdentifier> = []

    /// One page's handler: only `page`'s own host.
    convenience init(page: PageDescriptor, root: URL, dynamicSource: (any PageDynamicResourceSource)? = nil) {
        let served = Served(page: page, root: root.standardizedFileURL.resolvingSymlinksInPath(), dynamicSource: dynamicSource)
        let host = page.id.lowercased()
        self.init { $0 == host ? served : nil }
    }

    /// A handler that resolves every request's host.
    init(resolve: @escaping (String) -> Served?) {
        self.resolve = resolve
    }

    private func served(_ url: URL) -> Served? {
        guard url.scheme?.lowercased() == PageDescriptor.scheme, let host = url.host?.lowercased() else { return nil }
        return resolve(host)
    }

    /// The page's directory inside this module's resource bundle (`Resources/pages/<resource>`).
    static func bundledRoot(for page: PageDescriptor) -> URL? {
        Bundle.module.url(forResource: page.resource, withExtension: nil, subdirectory: "pages")
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let request = task.request
        guard request.httpMethod.map({ $0 == "GET" }) ?? true,
              let url = request.url, let served = served(url),
              Self.route(for: url, page: served.page, root: served.root) != nil
        else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let id = ObjectIdentifier(task)
        active.insert(id)
        // task-owner: one file read or dynamic lookup per scheme task; a stopped task is never answered
        Task { @MainActor [weak self] in
            guard let self else { return }
            let reply = await self.reply(to: url)
            guard self.active.remove(id) != nil else { return }
            guard let reply else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            task.didReceive(reply.response)
            if !reply.body.isEmpty { task.didReceive(reply.body) }
            task.didFinish()
        }
    }

    /// The reply for a GET of `url`: a bundled file (nil when missing or outside the root, as
    /// before), or the dynamic source's answer (a 404 when it has none).
    func reply(to url: URL) async -> Reply? {
        guard let served = served(url) else { return nil }
        let page = served.page
        switch Self.route(for: url, page: page, root: served.root) {
        case nil:
            return nil
        case .file(let file):
            guard let data = await Self.read(file) else { return nil }
            return Self.reply(url: url, page: page, status: 200, mimeType: Self.mimeType(forExtension: file.pathExtension), body: data)
        case .dynamic(let request):
            guard let resource = await served.dynamicSource?.resource(for: request) else {
                return Self.reply(url: url, page: page, status: 404, mimeType: "text/plain", body: Data())
            }
            let fallback = Self.mimeType(forExtension: request.path.last.map { ($0 as NSString).pathExtension } ?? "")
            let type = resource.mimeType.flatMap(Self.validMIMEType) ?? fallback
            return Self.reply(url: url, page: page, status: 200, mimeType: type, body: resource.data)
        }
    }

    /// A response with the headers every page response carries.
    nonisolated static func reply(url: URL, page: PageDescriptor, status: Int, mimeType: String, body: Data) -> Reply {
        let headers = [
            "Content-Type": mimeType, "Content-Length": String(body.count), "Cache-Control": "no-store",
            "Content-Security-Policy": page.csp.header, "X-Content-Type-Options": "nosniff",
        ]
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
            ?? HTTPURLResponse(url: url, mimeType: mimeType, expectedContentLength: body.count, textEncodingName: nil)
        return Reply(response: response, body: body)
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task))
    }

    @concurrent nonisolated static func read(_ file: URL) async -> Data? {
        // concurrency-allow: @concurrent, so this read never runs on the main actor
        try? Data(contentsOf: file, options: .mappedIfSafe)
    }

    /// Where `url` goes: a dynamic prefix of the page, else the file it names inside `root`. Nil
    /// for another scheme or page, a path with `.` or `..` components, or a path that leaves
    /// `root`. An empty path is the page's ``PageDescriptor/entry``.
    nonisolated static func route(for url: URL, page: PageDescriptor, root: URL) -> Route? {
        guard page.owns(url) else { return nil }
        var components = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if components.isEmpty { components = [page.entry] }
        guard !components.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        if let prefix = components.first, page.dynamicPrefixes.contains(prefix) {
            return .dynamic(PageResourceRequest(prefix: prefix, path: Array(components.dropFirst()), url: url))
        }
        return fileURL(components: components, root: root).map(Route.file)
    }

    /// The file `url` names inside `root`, or nil (see ``route(for:page:root:)``). A path under
    /// a dynamic prefix is never a file.
    nonisolated static func fileURL(for url: URL, page: PageDescriptor, root: URL) -> URL? {
        guard case .file(let file) = route(for: url, page: page, root: root) else { return nil }
        return file
    }

    private nonisolated static func fileURL(components: [String], root: URL) -> URL? {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let file = components.reduce(base) { $0.appendingPathComponent($1) }.standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(base.path + "/") else { return nil }
        return file
    }

    /// `type` when it is a plain `type/subtype` with an optional `charset` (no header injection),
    /// else nil.
    nonisolated static func validMIMEType(_ type: String) -> String? {
        let pattern = #"^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+(; ?charset=[A-Za-z0-9_.-]+)?$"#
        return type.range(of: pattern, options: .regularExpression) != nil ? type : nil
    }

    nonisolated static func mimeType(forExtension pathExtension: String) -> String {
        // Module scripts need a JavaScript type, and UTType does not know every extension (.mjs).
        switch pathExtension.lowercased() {
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "html": return "text/html"
        case "json": return "application/json"
        case "wasm": return "application/wasm"
        default: break
        }
        return UTType(filenameExtension: pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}

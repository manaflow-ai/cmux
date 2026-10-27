import CmuxNextSignposts
import CmuxNextTrace
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
/// `cmux-page://cmux.shared/` is answered for every page from ``sharedRoot`` (or the overlay, Debug
/// override or web update that also serves pages) by ``PageSharedChunks``' rules: its `.js` and
/// `.css` files only, only to a first-party page origin, never to a navigation.
///
/// Absorbed from the Settings lead's `SettingsPageSchemeHandler` (branch
/// feat-cmux-next-settings-react), generalized to every page.
final class PageSchemeHandler: NSObject, WKURLSchemeHandler {

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

    struct Served {
        let page: PageDescriptor
        let root: URL
        weak var dynamicSource: (any PageDynamicResourceSource)?
    }

    private let resolve: (String) -> Served?
    /// The folder `cmux-page://cmux.shared/` serves (``PageSharedChunks/bundledRoot``; tests pass their
    /// own), nil when there is none: every shared request fails.
    let sharedRoot: URL?
    /// The Debug override of the shared folder (``PageSharedChunks/debugRoot``; tests pass their own),
    /// read before ``sharedRoot``.
    let debugSharedRoot: URL?
    /// The Vite server pages load from (``PageDevServer``, Debug only), nil for the bundled pages.
    let devServer: PageDevServer?
    /// Fetches one file from ``devServer`` (tests replace it).
    var fetchDevServer: @Sendable (URL) async -> (Data, HTTPURLResponse)? = { await PageDevServer.fetch($0) }
    /// The live override (``WebDevOverride/current``; tests replace it).
    var liveOverride: @Sendable () -> WebDevOverride = { WebDevOverride.current }
    /// Tasks started and not yet answered or stopped; a stopped task must not be answered.
    private var active: Set<ObjectIdentifier> = []
    /// The active web update (``WebBundleOverlay/shared``; tests pass their own).
    var bundleOverlay: WebBundleOverlay = .shared
    /// The web update folder each served document loaded from, by its web view: every later
    /// request of that document comes from the same folder, so a document kept across a swap
    /// (hidden, frozen) loads its lazy chunks from its own build (``WebBundleOverlay/Pin``).
    private var documentPins: [ObjectIdentifier: DocumentPin] = [:]

    private struct DocumentPin {
        weak var view: WKWebView?
        let pin: WebBundleOverlay.Pin
    }
    /// Where the `webui.scheme` slices go (``PageTraceSink``).
    private let trace: any PageTraceSink

    /// The handler's main-thread steps of one task, each a ``SignpostName/webuiScheme`` slice (begin arg0).
    nonisolated enum TracePart: UInt64 {
        /// The start callback: the request checks.
        case start = 0
        /// The answer turn: the response and body handed to WebKit.
        case answer = 1
        /// A synchronous step of ``reply(to:page:)`` between its awaits: the lookup, the route, the headers.
        case reply = 2
    }

    init(page: PageDescriptor, root: URL, dynamicSource: (any PageDynamicResourceSource)? = nil,
         devServer: PageDevServer? = PageDevServer.current, trace: any PageTraceSink = TraceRuntime.shared,
         sharedRoot: URL? = PageSharedChunks.bundledRoot, debugSharedRoot: URL? = PageSharedChunks.debugRoot) {
        self.devServer = devServer
        self.trace = trace
        self.sharedRoot = sharedRoot
        self.debugSharedRoot = debugSharedRoot
        let served = Served(page: page, root: root.standardizedFileURL.resolvingSymlinksInPath(), dynamicSource: dynamicSource)
        let host = page.id.lowercased()
        resolve = { $0 == host ? served : nil }
    }

    /// Creates a handler whose page origin resolves to one of the supplied bundled pages.
    init(resolve: @escaping (String) -> Served?, devServer: PageDevServer? = PageDevServer.current,
         trace: any PageTraceSink = TraceRuntime.shared, sharedRoot: URL? = PageSharedChunks.bundledRoot,
         debugSharedRoot: URL? = PageSharedChunks.debugRoot) {
        self.resolve = resolve
        self.devServer = devServer
        self.trace = trace
        self.sharedRoot = sharedRoot
        self.debugSharedRoot = debugSharedRoot
    }

    private func served(_ url: URL) -> Served? {
        guard url.scheme?.lowercased() == PageDescriptor.scheme,
              let host = url.host?.lowercased() else { return nil }
        return resolve(host)
    }

    /// The page's directory inside this module's resource bundle (`Resources/pages/<resource>`).
    static func bundledRoot(for page: PageDescriptor) -> URL? {
        Bundle.module.url(forResource: page.resource, withExtension: nil, subdirectory: "pages")
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let page = PageWebView.traceID(showing: webView)
        trace.begin(.webuiScheme, arg0: TracePart.start.rawValue, arg1: page)
        var failed: UInt64 = 0
        defer { trace.end(.webuiScheme, arg0: failed, arg1: 0) }
        let request = task.request
        let origin = request.value(forHTTPHeaderField: "Origin")
        guard request.httpMethod.map({ $0 == "GET" }) ?? true,
              let url = request.url, accepts(url, origin: origin, mainDocument: request.mainDocumentURL)
        else {
            failed = 1
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let id = ObjectIdentifier(task)
        active.insert(id)
        let range = request.value(forHTTPHeaderField: "Range")
        let mainDocument = request.mainDocumentURL
        let loadsDocument = Self.isMainDocument(url, mainDocument: mainDocument)
        // task-owner: one file read or dynamic lookup per scheme task; a stopped task is never answered
        Task { @MainActor [weak self, weak webView] in
            guard let self else { return }
            let pin = await self.documentPin(of: webView, loadsDocument: loadsDocument)
            let reply: Reply? = if PageSharedChunks.isShared(url) {
                await self.sharedReply(to: url, origin: origin, mainDocument: mainDocument, page: page, pin: pin)
            } else {
                await self.reply(to: url, range: range, page: page, pin: pin)
            }
            guard self.active.remove(id) != nil else { return }
            self.trace.begin(.webuiScheme, arg0: TracePart.answer.rawValue, arg1: page)
            guard let reply else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                self.trace.end(.webuiScheme, arg0: 1, arg1: 0)
                return
            }
            task.didReceive(reply.response)
            if !reply.body.isEmpty { task.didReceive(reply.body) }
            task.didFinish()
            self.trace.end(.webuiScheme, arg0: 0, arg1: UInt64(reply.body.count))
        }
    }

    /// Whether `url` is the main frame's document (its request names itself as the main document):
    /// the load that pins the web update folder the document's later requests come from.
    nonisolated static func isMainDocument(_ url: URL, mainDocument: URL?) -> Bool {
        guard let mainDocument else { return false }
        func stripped(_ url: URL) -> String? {
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            parts.fragment = nil
            return parts.string
        }
        return stripped(url) == stripped(mainDocument)
    }

    /// The pin of the document `webView` shows: a new one, of the folder served now, when the request
    /// loads the document itself; else the one its document load took (nil: the folder served now).
    private func documentPin(of webView: WKWebView?, loadsDocument: Bool) async -> WebBundleOverlay.Pin? {
        guard let webView else { return nil }
        let id = ObjectIdentifier(webView)
        guard loadsDocument else { return documentPins[id].flatMap { $0.view === webView ? $0.pin : nil } }
        let pin = await bundleOverlay.pin()
        documentPins = documentPins.filter { $0.value.view != nil }
        documentPins[id] = DocumentPin(view: webView, pin: pin)
        return pin
    }

    /// Whether the start callback takes a request for `url`: a shared chunk that ``sharedRoot`` may
    /// answer for `origin` (``PageSharedChunks/allowedOrigin(for:origin:mainDocument:)``), or a route of
    /// a served page.
    private func accepts(_ url: URL, origin: String?, mainDocument: URL?) -> Bool {
        if PageSharedChunks.isShared(url) {
            return sharedRoot != nil && PageSharedChunks.allowedOrigin(for: url, origin: origin, mainDocument: mainDocument) != nil
        }
        guard let served = served(url) else { return false }
        return Self.route(for: url, page: served.page, root: served.root) != nil
    }

    /// The reply for a GET of the shared chunk `url` with the `Origin` header `origin` and the top
    /// document `mainDocument`: the `.js` or `.css` file of the first folder that holds it, among the
    /// live override's overlay, ``debugSharedRoot``, the web update's copy of ``sharedRoot`` (in
    /// `pin`'s folder, the asking document's, else the active one) and ``sharedRoot``
    /// (``PageSharedChunks/roots(overlay:debug:update:bundled:)``), the same roots a page's
    /// own files come from; readable by that origin only; nil, so the task fails, for a navigation, an
    /// origin that may not read it, or any other file (``PageSharedChunks``). No ``devServer`` serves it.
    func sharedReply(to url: URL, origin: String?, mainDocument: URL? = nil, page: UInt64 = 0,
                     pin: WebBundleOverlay.Pin? = nil) async -> Reply? {
        let start = step(page) { () -> (allowed: String, root: URL, overlay: URL?)? in
            guard let root = self.sharedRoot,
                  let allowed = PageSharedChunks.allowedOrigin(for: url, origin: origin, mainDocument: mainDocument)
            else { return nil }
            return (allowed, root, self.liveOverride().overlay)
        }
        guard let start else { return nil }
        let update = await bundleOverlay.root(for: start.root, pin: pin)
        let roots = step(page) {
            PageSharedChunks.roots(overlay: start.overlay, debug: self.debugSharedRoot, update: update, bundled: start.root)
        }
        for root in roots {
            guard let file = step(page, { PageSharedChunks.file(for: url, root: root) }),
                  let data = await Self.read(file) else { continue }
            return step(page) { PageSharedChunks.reply(url: url, allowedOrigin: start.allowed, body: data, file: file) }
        }
        return nil
    }

    /// The reply for a GET of `url`: a bundled file (nil when missing or outside the root, as
    /// before), or the dynamic source's answer (a 404 when it has none). With a ``devServer`` a
    /// page file comes from that server instead. The live override (``WebDevOverride``) is read
    /// per request: its server's answers, else (a stopped server, a 4xx or 5xx) its overlay
    /// folder's file, else, with an active web update (``WebBundleOverlay``), the update's copy
    /// of the page's folder, else the bundled one.
    ///
    /// `page` is the asking page's trace id: each synchronous step runs in a ``SignpostName/webuiScheme``
    /// slice of part ``TracePart/reply``, so with the start and answer turns the slices of a page sum the
    /// handler's main-thread time (a dynamic source's own work is the source's).
    ///
    /// `range` is the request's `Range` header, which a dynamic source answers in byte ranges (media).
    /// `pin` is the asking document's web update folder (``WebBundleOverlay/Pin``); nil: the active one.
    func reply(to url: URL, range: String? = nil, page: UInt64 = 0, pin: WebBundleOverlay.Pin? = nil) async -> Reply? {
        let start = step(page) { () -> (served: Served, live: WebDevOverride, server: PageDevServer?, remote: URL?)? in
            guard let found = self.served(url) else { return nil }
            let live = self.liveOverride()
            let server = self.devServer ?? live.server
            return (found, live, server, server?.url(for: url, page: found.page))
        }
        guard let start else { return nil }
        let served = start.served
        if let server = start.server, let remote = start.remote {
            if let (body, response) = await fetchDevServer(remote) {
                let answer = step(page) { () -> Reply? in
                    guard server.isOwn(response.url), self.devServer != nil || response.statusCode < 400 else { return nil }
                    let type = response.value(forHTTPHeaderField: "Content-Type").flatMap(Self.validMIMEType)
                        ?? Self.mimeType(forExtension: remote.pathExtension)
                    return Self.reply(url: url, csp: server.csp(for: served.page), status: response.statusCode,
                                      mimeType: type, body: body)
                }
                if let answer { return answer }
            }
            // The launch variable's server (Debug) fails the request, as before.
            if self.devServer != nil { return nil }
        }
        let update = await bundleOverlay.root(for: served.root, pin: pin)
        let destination = step(page) {
            Self.route(for: url, page: served.page,
                       root: start.live.overlayRoot(for: served.page, bundledRoot: served.root) ?? update)
        }
        switch destination {
        case nil:
            return nil
        case .file(let file):
            guard let data = await Self.read(file) else { return nil }
            return step(page) {
                Self.reply(url: url, page: served.page, status: 200,
                           mimeType: Self.mimeType(forExtension: file.pathExtension), body: data)
            }
        case .dynamic(let found):
            let request = PageResourceRequest(prefix: found.prefix, path: found.path, url: found.url, range: range)
            let resource = await served.dynamicSource?.resource(for: request)
            return step(page) { Self.dynamicReply(url: url, page: served.page, request: request, resource: resource) }
        }
    }

    /// The WebKit reply for a dynamic request: the source's resource with its status, range headers
    /// and type, served under the page's CSP, or under its own sandboxed policy
    /// (``PageResource/sandboxedPolicy``); a 404 without a resource.
    nonisolated static func dynamicReply(url: URL, page: PageDescriptor, request: PageResourceRequest,
                                         resource: PageResource?) -> Reply {
        guard let resource, resource.sandboxedPolicy?.contains(where: \.isNewline) != true else {
            let missing = PageChromiumResponse.notFound
            return reply(url: url, page: page, status: missing.status, mimeType: missing.mimeType, body: missing.body)
        }
        var extra: [String: String] = [:]
        if resource.acceptsRanges { extra["Accept-Ranges"] = "bytes" }
        if let contentRange = resource.contentRange { extra["Content-Range"] = contentRange }
        let policy = resource.sandboxedPolicy.map { "sandbox allow-scripts; " + $0 } ?? page.csp.header
        return reply(url: url, policy: policy, status: resource.status, mimeType: mimeType(of: resource, for: request),
                     body: resource.data, extra: extra)
    }

    /// The resource's own type when it is well formed, else the type of the request's last path
    /// component's extension.
    nonisolated static func mimeType(of resource: PageResource, for request: PageResourceRequest) -> String {
        resource.mimeType.flatMap(validMIMEType)
            ?? mimeType(forExtension: request.path.last.map { ($0 as NSString).pathExtension } ?? "")
    }

    /// Runs one synchronous main-thread step of a reply to `page` inside a ``TracePart/reply`` slice.
    private func step<T>(_ page: UInt64, _ body: () -> T) -> T {
        trace.begin(.webuiScheme, arg0: TracePart.reply.rawValue, arg1: page)
        defer { trace.end(.webuiScheme, arg0: 0, arg1: 0) }
        return body()
    }

    /// The answer to a Chromium page's request under a dynamic prefix: the source's resource with
    /// its type (a malformed or missing type falls back to the name's extension), else a 404.
    /// Chromium's answer has no headers of its own, so a partial answer (a range of a larger media
    /// file) and a document with its own sandboxed policy are 404s there.
    static func dynamicResponse(to request: PageResourceRequest,
                                source: (any PageDynamicResourceSource)?) async -> PageChromiumResponse {
        guard let resource = await source?.resource(for: request), resource.status == 200,
              resource.contentRange == nil, resource.sandboxedPolicy == nil else { return .notFound }
        return PageChromiumResponse(status: 200, mimeType: mimeType(of: resource, for: request), body: resource.data)
    }

    /// The dynamic request `url` makes of `page`, nil when it is not under one of the page's dynamic
    /// prefixes (another origin, a static file, a `.` or `..` component).
    nonisolated static func dynamicRequest(for url: URL, page: PageDescriptor) -> PageResourceRequest? {
        guard case .dynamic(let request)? = route(for: url, page: page, root: URL(fileURLWithPath: "/", isDirectory: true)) else {
            return nil
        }
        return request
    }

    /// A response with the headers every page response carries.
    nonisolated static func reply(url: URL, page: PageDescriptor, status: Int, mimeType: String, body: Data) -> Reply {
        reply(url: url, csp: page.csp, status: status, mimeType: mimeType, body: body)
    }

    /// A response with `csp` and the other headers every page response carries.
    nonisolated static func reply(url: URL, csp: PageCSP, status: Int, mimeType: String, body: Data) -> Reply {
        reply(url: url, policy: csp.header, status: status, mimeType: mimeType, body: body)
    }

    /// A response with the Content Security Policy header `policy`, the other headers every page
    /// response carries, and `extra` (a media range's `Content-Range` and `Accept-Ranges`).
    nonisolated static func reply(url: URL, policy: String, status: Int, mimeType: String, body: Data,
                                  extra: [String: String] = [:]) -> Reply {
        var headers = [
            "Content-Type": mimeType, "Content-Length": String(body.count), "Cache-Control": "no-store",
            "Content-Security-Policy": policy, "X-Content-Type-Options": "nosniff",
        ]
        headers.merge(extra) { own, _ in own }
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

    /// The file `components` names inside `root` (symlinks resolved), nil when it leaves `root`.
    nonisolated static func fileURL(components: [String], root: URL) -> URL? {
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

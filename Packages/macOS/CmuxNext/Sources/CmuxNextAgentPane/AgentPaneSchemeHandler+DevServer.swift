import CmuxNextPages
import Foundation
import WebKit

/// The live web override (``WebDevOverride``) for the bundled pane: its files come from the
/// overlay's `agent-pane/` folder, or from the Vite server, still under `cmux-agent://pane`, so the
/// page keeps its origin, bridge and trust. A request the server cannot answer gets the bundled
/// (or overlay) file, so a stopped server leaves the bundled pane.
extension AgentPaneSchemeHandler {
    /// Where files are read: the overlay's `agent-pane/` when it holds a page, else the bundle.
    var servedRoot: URL {
        WebDevOverride.current.overlayRoot(root.lastPathComponent) ?? root
    }

    /// The policy a dev server's non-document response is served with. A Vite worker is a module
    /// that imports its dependencies from the same origin.
    nonisolated static let devResourcePolicy = "default-src 'self' 'wasm-unsafe-eval'"

    /// The server URL for pane request `url`: the document (`/` or `/index.html`) is the server's
    /// `/agent-pane/index.html`, any other path (`/@vite/client`, `/src/...`, `/node_modules/...`)
    /// the same path and query there. Nil for another scheme or host, or a `.` or `..` component.
    nonisolated static func devServerURL(for url: URL, server: PageDevServer) -> URL? {
        guard url.scheme?.lowercased() == AgentPaneSource.bundledScheme,
              url.host?.lowercased() == AgentPaneSource.bundledHost
        else { return nil }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        var base = server.root.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        if components.isEmpty || components == ["index.html"] {
            return URL(string: base + "/agent-pane/index.html")
        }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = parts?.percentEncodedPath ?? url.path
        let query = parts?.percentEncodedQuery.map { "?" + $0 } ?? ""
        return URL(string: base + path + query)
    }

    /// Answers `task` with the server's file at `remote`, else the bundled one, else fails it. The
    /// document names its source (``WebSource``) and records it for `webView` in DEV and NIGHTLY.
    func serveDevServer(_ remote: URL, server: PageDevServer, url: URL, task: any WKURLSchemeTask, webView: WKWebView) {
        let id = ObjectIdentifier(task)
        active.insert(id)
        let fallback = Self.fileURL(for: url, root: servedRoot), overlaid = servedRoot != root
        // task-owner: one fetch per scheme task; a stopped task is never answered
        Task { @MainActor [weak self, weak webView] in
            var reply: (Data, [String: String])?
            let request = server.request(for: remote)
            // The document must be HTML, else the bundled pane: an answer drawn as text shows its source.
            let document = remote.path.hasSuffix("/agent-pane/index.html")
            if let (body, response) = await PageDevServer.fetch(request), server.answered(response, to: request), response.statusCode < 400,
               !document || PageDevServer.isHTML(response.value(forHTTPHeaderField: "Content-Type")) {
                let type = response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
                var headers = ["Content-Type": type, "Content-Length": String(body.count), "Cache-Control": "no-store",
                               "X-Content-Type-Options": "nosniff"]
                // The document's policy is its meta tag (src/agent-session/acpmux/index.html).
                if !type.hasPrefix("text/html") { headers["Content-Security-Policy"] = Self.devResourcePolicy }
                let marked = document && WebSource.isShown ? Self.marked(body, .devServer(server.root), for: webView) : body
                headers["Content-Length"] = String(marked.count)
                reply = (marked, headers)
            } else if let fallback, var data = await Self.read(fallback) {
                if document, WebSource.isShown {
                    let source: WebSource = overlaid ? .overlay(commit: WebDevOverride.current.overlayCommit) : .bundle
                    data = Self.marked(data, source, for: webView)
                }
                reply = (data, Self.headers(for: fallback, length: data.count))
            }
            guard let self, self.active.remove(id) != nil else { return }
            guard let (body, headers) = reply else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
            task.didReceive(response ?? URLResponse(url: url, mimeType: nil, expectedContentLength: body.count, textEncodingName: nil))
            task.didReceive(body)
            task.didFinish()
        }
    }

    /// `html` naming `source`, which is recorded for `webView` (``WebBundleServedViews/recordWebSource(_:for:)``).
    static func marked(_ html: Data, _ source: WebSource, for webView: WKWebView?) -> Data {
        if let webView { WebBundleServedViews.shared.recordWebSource(source, for: webView) }
        return source.marked(html)
    }
}

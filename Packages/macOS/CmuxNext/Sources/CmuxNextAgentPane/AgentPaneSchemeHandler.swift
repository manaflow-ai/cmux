import CmuxNextPages
import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves the bundled agent pane under `cmux-agent://pane/`, so the page has
/// a real origin (`cmux-agent://pane`) instead of the `null` origin of a
/// `file://` page. acpmux's localhost listeners then allow exactly this
/// origin (plans/cmux-next/identity.md).
///
/// Only GET requests for files directly beside the page, and for the render
/// frame (`AgentPaneRenderFrame`), are answered; any other host, an escaping
/// path or a missing file fails the request.
/// Media the host granted the page (``AgentPaneMediaGrants``) is served from
/// `__media/` in byte ranges, and the chart library from `__lib/vega.js`.
final class AgentPaneSchemeHandler: NSObject, WKURLSchemeHandler {
    private let root: URL
    /// The markdown viewer's bundled libraries (the chart library's files).
    let libraries: URL?

    init(root: URL, libraries: URL? = Bundle.main.resourceURL.map(PageDescriptor.markdownLibraries(inAppResources:))) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.libraries = libraries
    }

    /// Tasks started and not yet answered or stopped; a stopped task must not be answered.
    var active: Set<ObjectIdentifier> = []

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        if task.request.httpMethod.map({ $0 == "GET" }) ?? true,
           let url = task.request.url, AgentPaneRenderFrame.isFrame(url) {
            let data = AgentPaneRenderFrame.document
            let headers = AgentPaneRenderFrame.headers(length: data.count)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
            task.didReceive(response ?? URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
            return
        }
        if task.request.httpMethod.map({ $0 == "GET" }) ?? true, let url = task.request.url, let media = Self.mediaFile(for: url) {
            return serveMedia(media, url: url, task: task)
        }
        if task.request.httpMethod.map({ $0 == "GET" }) ?? true, let url = task.request.url, Self.isLibrary(url) {
            return serveLibrary(url: url, task: task)
        }
        guard task.request.httpMethod.map({ $0 == "GET" }) ?? true,
              let url = task.request.url,
              let file = Self.fileURL(for: url, root: root)
        else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let id = ObjectIdentifier(task)
        active.insert(id)
        // task-owner: one file read per scheme task; a stopped task is never answered
        Task { @MainActor [weak self] in
            let data = await Self.read(file)
            guard let self, self.active.remove(id) != nil else { return }
            guard let data else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: Self.headers(for: file, length: data.count)
            )
            task.didReceive(response ?? URLResponse(url: url, mimeType: nil, expectedContentLength: data.count, textEncodingName: nil))
            task.didReceive(data)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task))
    }

    /// Reads `file` off the main thread.
    @concurrent nonisolated static func read(_ file: URL) async -> Data? {
        // concurrency-allow: @concurrent, so this read never runs on the main actor
        try? Data(contentsOf: file, options: .mappedIfSafe)
    }

    /// The file `url` names inside `root`, or nil for another scheme or
    /// host, an empty path, or a path that leaves `root`.
    nonisolated static func fileURL(for url: URL, root: URL) -> URL? {
        guard url.scheme?.lowercased() == AgentPaneSource.bundledScheme,
              url.host?.lowercased() == AgentPaneSource.bundledHost
        else { return nil }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, !components.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let file = components.reduce(base) { $0.appendingPathComponent($1) }.standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(base.path + "/") else { return nil }
        return file
    }

    nonisolated static func mimeType(forExtension pathExtension: String) -> String {
        UTType(filenameExtension: pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}

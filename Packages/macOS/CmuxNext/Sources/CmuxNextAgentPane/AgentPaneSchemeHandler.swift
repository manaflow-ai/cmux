import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves the bundled agent pane under `cmux-agent://pane/`, so the page has
/// a real origin (`cmux-agent://pane`) instead of the `null` origin of a
/// `file://` page. acpmux's localhost listeners then allow exactly this
/// origin (plans/cmux-next/identity.md).
///
/// Only GET requests for files directly beside the page are answered; any
/// other host, an escaping path or a missing file fails the request.
final class AgentPaneSchemeHandler: NSObject, WKURLSchemeHandler {
    private let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Tasks started and not yet answered or stopped; a stopped task must not be answered.
    private var active: Set<ObjectIdentifier> = []

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
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

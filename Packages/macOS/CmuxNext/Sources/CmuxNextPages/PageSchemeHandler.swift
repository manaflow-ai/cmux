import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves bundled pages under `cmux-page://<page id>/` (one origin per page). Only GET requests
/// for files inside the page's own resource directory are answered; another host, an escaping
/// path or a missing file fails the request. `/` is the page's `index.html`. Every response
/// carries the page CSP: no network, no remote code (the page talks to the app through its bridge).
///
/// Absorbed from the Settings lead's `SettingsPageSchemeHandler` (branch
/// feat-cmux-next-settings-react), generalized to every page.
final class PageSchemeHandler: NSObject, WKURLSchemeHandler {
    /// The strict policy every page starts with (``PageCSP/strict``).
    static var contentSecurityPolicy: String { PageCSP.strict.header }

    private let page: PageDescriptor
    private let root: URL
    /// Tasks started and not yet answered or stopped; a stopped task must not be answered.
    private var active: Set<ObjectIdentifier> = []

    init(page: PageDescriptor, root: URL) {
        self.page = page
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The page's directory inside this module's resource bundle (`Resources/pages/<resource>`).
    static func bundledRoot(for page: PageDescriptor) -> URL? {
        Bundle.module.url(forResource: page.resource, withExtension: nil, subdirectory: "pages")
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard task.request.httpMethod.map({ $0 == "GET" }) ?? true,
              let url = task.request.url,
              let file = Self.fileURL(for: url, page: page, root: root)
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
            let type = Self.mimeType(forExtension: file.pathExtension)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": type, "Content-Length": String(data.count), "Cache-Control": "no-store",
                "Content-Security-Policy": self.page.csp.header,
            ])
            task.didReceive(response ?? URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
            task.didReceive(data)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task))
    }

    @concurrent nonisolated static func read(_ file: URL) async -> Data? {
        // concurrency-allow: @concurrent, so this read never runs on the main actor
        try? Data(contentsOf: file, options: .mappedIfSafe)
    }

    /// The file `url` names inside `root`, or nil for another scheme or page, a path with `.`
    /// or `..` components, or a path that leaves `root`. An empty path is `index.html`.
    nonisolated static func fileURL(for url: URL, page: PageDescriptor, root: URL) -> URL? {
        guard page.owns(url) else { return nil }
        var components = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if components.isEmpty { components = ["index.html"] }
        guard !components.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let file = components.reduce(base) { $0.appendingPathComponent($1) }.standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(base.path + "/") else { return nil }
        return file
    }

    nonisolated static func mimeType(forExtension pathExtension: String) -> String {
        UTType(filenameExtension: pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}

import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves the bundled web Settings page under `cmux-settings://page/`, so
/// the page has a real origin (`cmux-settings://page`) that the bridge pins
/// (plans/cmux-next/settings-react.md section 5). Only GET requests for
/// files inside the page directory are answered; another host, an escaping
/// path or a missing file fails the request.
final class SettingsPageSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "cmux-settings"
    static let host = "page"
    static let origin = "\(scheme)://\(host)"
    /// The page URL the tab loads; the route follows the hash.
    static let pageURL = URL(string: "\(origin)/index.html")!

    private let root: URL
    /// Tasks started and not yet answered or stopped; a stopped task must not be answered.
    private var active: Set<ObjectIdentifier> = []

    init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The page directory inside the module's resource bundle.
    static func bundledRoot() -> URL? {
        Bundle.module.url(forResource: "settings-page", withExtension: nil)
    }

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
            let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": type, "Content-Length": String(data.count), "Cache-Control": "no-store",
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

    /// The file `url` names inside `root`, or nil for another scheme or
    /// host, an empty path, or a path that leaves `root`.
    nonisolated static func fileURL(for url: URL, root: URL) -> URL? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host else { return nil }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, !components.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let file = components.reduce(base) { $0.appendingPathComponent($1) }.standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(base.path + "/") else { return nil }
        return file
    }
}

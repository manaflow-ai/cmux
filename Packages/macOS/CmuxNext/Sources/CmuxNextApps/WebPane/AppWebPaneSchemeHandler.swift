import CmuxNextCompat
import Foundation
import WebKit

/// Serves a web pane's own files under `cmux-app://<namespace>/`
/// (custom-panes-DESIGN.md section 2). Only GET requests for files inside
/// `runtime.web.root` are answered, each with the host's policy
/// (``AppWebPane/headers(for:length:)``); any other host, an escaping path or
/// a missing file fails the request.
final class AppWebPaneSchemeHandler: NSObject, WKURLSchemeHandler {
    var pane: AppWebPane?
    /// Tasks started and not yet answered or stopped; a stopped task must not be answered.
    private var active: Set<ObjectIdentifier> = []

    init(pane: AppWebPane) {
        self.pane = pane
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let pane, task.request.httpMethod.map({ $0 == "GET" }) ?? true,
              let url = task.request.url, let file = pane.file(for: url)
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
            let headers = pane.headers(for: file, length: data.count)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
            task.didReceive(response ?? URLResponse(url: url, mimeType: nil, expectedContentLength: data.count, textEncodingName: nil))
            task.didReceive(data)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task))
    }

    /// Reads `file` off the main thread; nil for a folder or a missing file.
    @concurrent nonisolated static func read(_ file: URL) async -> Data? {
        // concurrency-allow: @concurrent, so this read never runs on the main actor
        var isDirectory: ObjCBool = false
        guard FileManager.checked.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return try? Data(blockingContentsOf: file, options: .mappedIfSafe)
    }
}

import CmuxNextCompat
import Foundation
import CmuxNextWakeups
import WebKit

/// Serves a web pane's own files under `cmux-app://<namespace>/`
/// (custom-panes-DESIGN.md section 2). Only GET requests for files inside
/// `runtime.web.root` are answered, each with the host's policy
/// (``AppWebPane/headers(for:length:)``); any other host, an escaping path or
/// a missing file fails the request.
final class AppWebPaneSchemeHandler: NSObject, WKURLSchemeHandler {
    var pane: AppWebPane? {
        didSet { generation += 1 }
    }
    private var generation = 0
    private let work: BackgroundWork
    private let readFile: @Sendable (AppWebPane, URL) -> (file: URL, data: Data)?
    /// Tasks started and not yet answered or stopped; a stopped task must not be answered.
    private var active: Set<ObjectIdentifier> = []

    init(pane: AppWebPane, work: BackgroundWork,
         readFile: @escaping @Sendable (AppWebPane, URL) -> (file: URL, data: Data)? = AppWebPaneSchemeHandler.read) {
        self.pane = pane
        self.work = work
        self.readFile = readFile
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let pane, task.request.httpMethod.map({ $0 == "GET" }) ?? true,
              let url = task.request.url
        else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let id = ObjectIdentifier(task)
        let generation = generation
        let work = work
        let readFile = readFile
        active.insert(id)
        // task-owner: one file read per scheme task; a stopped task is never answered
        Task { @MainActor [weak self] in
            let resource = try? await work.run(.userVisible, mayBlock: .files) { readFile(pane, url) }
            guard let self, self.active.remove(id) != nil else { return }
            guard self.generation == generation else {
                task.didFailWithError(URLError(.cancelled))
                return
            }
            guard let (file, data) = resource else {
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

    /// Resolves containment and reads on BackgroundWork's blocking file lane.
    nonisolated static func read(_ pane: AppWebPane, _ url: URL) -> (file: URL, data: Data)? {
        guard let file = pane.file(for: url) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.checked.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        guard let data = try? Data(blockingContentsOf: file, options: .mappedIfSafe) else { return nil }
        return (file, data)
    }
}

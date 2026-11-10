@testable import CmuxNextApps
import CmuxNextWakeups
import Foundation
import Testing
import WebKit

/// The scheme callback returns before file work and discards results from a replaced pane.
@MainActor
struct AppWebPaneSchemeHandlerTests {
    @Test(.timeLimit(.minutes(1))) func resourceResolutionAndReadingRunOffMain() async throws {
        let (bundle, pane) = try fixture()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let handler = AppWebPaneSchemeHandler(pane: pane, work: BackgroundWork(), readFile: { pane, url in
            #expect(!Thread.isMainThread, "containment and file reads must share the background file lane")
            return AppWebPaneSchemeHandler.read(pane, url)
        })
        let task = SchemeTask(url: pane.entryURL)
        let web = WKWebView()
        handler.webView(web, start: task)
        #expect(task.data.isEmpty, "the synchronous WebKit callback must return before file work")
        for await _ in task.completed { break }
        #expect(task.error == nil)
        #expect(task.response?.statusCode == 200)
        #expect(String(data: task.data, encoding: .utf8) == "pane")
    }

    @Test(.timeLimit(.minutes(1))) func aReplacedPaneCannotPublishAnEarlierRead() async throws {
        let (bundle, pane) = try fixture()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let handler = AppWebPaneSchemeHandler(pane: pane, work: BackgroundWork())
        let task = SchemeTask(url: pane.entryURL)
        let web = WKWebView()
        handler.webView(web, start: task)
        handler.pane = nil
        for await _ in task.completed { break }
        #expect(task.error?.code == .cancelled)
        #expect(task.response == nil)
        #expect(task.data.isEmpty, "invalidation must revoke pending responses as well as the bridge")
    }

    private func fixture() throws -> (URL, AppWebPane) {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("pane-serving-\(UUID().uuidString)")
        let root = bundle.appendingPathComponent("web")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "pane".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let manifest = try #require(AppManifest(json: [
            "manifestVersion": 2, "id": "local/board", "name": "Board", "version": "1.0.0",
            "runtime": ["web": ["root": "web/"]],
            "implements": ["cmux.pane/1": ["web": "web/index.html", "title": "Board"]],
        ]))
        return (bundle, try #require(AppWebPane(manifest: manifest, bundle: bundle)))
    }
}

@MainActor
private final class SchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private(set) var response: HTTPURLResponse?
    private(set) var data = Data()
    private(set) var error: URLError?
    let (completed, completion) = AsyncStream.makeStream(of: Void.self)

    init(url: URL) {
        request = URLRequest(url: url)
    }

    func didReceive(_ response: URLResponse) { self.response = response as? HTTPURLResponse }
    func didReceive(_ data: Data) { self.data.append(data) }
    func didFinish() { completion.yield(); completion.finish() }
    func didFailWithError(_ error: any Error) {
        self.error = error as? URLError
        completion.yield()
        completion.finish()
    }
}

import AppKit
import Foundation
import Testing
import WebKit
@testable import CmuxNextAgentPane

/// In WebKit, under the bundled scheme handler's headers: the pane's highlight worker really
/// starts (a CSP or module mistake would make the pane fall back to the main thread), and a worker
/// served by the handler opens no connection.
@MainActor
@Suite struct AgentPaneHighlightWorkerWebKitTests {
    /// A web view on `cmux-agent://pane/<page>` served from `root`, loaded.
    private func load(root: URL, page: String) async throws -> (WKWebView, NSWindow) {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(AgentPaneSchemeHandler(root: root), forURLScheme: AgentPaneSource.bundledScheme)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(webView)
        webView.load(URLRequest(url: try #require(URL(string: "\(AgentPaneSource.bundledOrigin)/\(page)"))))
        // about:blank is "complete" at once: wait for the page's own document.
        let ready = "location.protocol === '\(AgentPaneSource.bundledScheme):' && document.readyState === 'complete'"
        for _ in 0..<200 {
            if (try? await webView.evaluateJavaScript(ready)) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(webView.url?.scheme == AgentPaneSource.bundledScheme)
        return (webView, window)
    }

    @Test func theBundledHighlightWorkerStartsAndAnswers() async throws {
        let page = try #require(AgentPaneView.bundledPage)
        let (webView, window) = try await load(root: page.deletingLastPathComponent(), page: page.lastPathComponent)
        defer { window.close() }
        // Any answer proves the module loaded and runs: an unknown request answers with an error.
        let script = """
        return await new Promise((done) => {
          const worker = new Worker("highlight-worker.js", { type: "module" });
          worker.onmessage = (event) => done("answered:" + event.data.type + ":" + event.data.id);
          worker.onerror = () => done("failed");
          worker.postMessage({ type: "probe", id: "p1" });
          setTimeout(() => done("silent"), 8000);
        });
        """
        let result = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(result == "answered:error:p1")
    }

    @Test func aWorkerServedByTheHandlerOpensNoConnection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pane-worker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>probe</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("""
        let fetched = "loaded";
        try { await fetch("\(AgentPaneSource.bundledOrigin)/index.html"); } catch (_) { fetched = "blocked"; }
        postMessage(fetched);
        """.utf8).write(to: root.appendingPathComponent("probe.js"))
        let (webView, window) = try await load(root: root, page: "index.html")
        defer { window.close() }
        let script = """
        const control = await fetch("probe.js").then(() => "loaded", () => "blocked");
        const worker = await new Promise((done) => {
          const probe = new Worker("probe.js", { type: "module" });
          probe.onmessage = (event) => done(event.data);
          probe.onerror = () => done("failed");
          setTimeout(() => done("silent"), 8000);
        });
        return control + "/" + worker;
        """
        let result = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? String
        // The page (no header policy) can fetch from its origin; the worker, under the header, cannot.
        #expect(result == "loaded/blocked")
    }
}

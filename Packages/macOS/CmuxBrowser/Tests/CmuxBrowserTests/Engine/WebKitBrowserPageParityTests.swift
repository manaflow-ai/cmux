import Foundation
import Testing
import WebKit
@testable import CmuxBrowser

/// Routing a WebKit panel through ``WebKitBrowserPage`` must not change what
/// the panel's existing `WKWebView` calls produce. Each test runs the same
/// operation both ways on a loaded page and compares the results.
@MainActor
@Suite(.serialized)
struct WebKitBrowserPageParityTests {
    private nonisolated static let page = """
    <!doctype html><title>parity</title><body><p id="p">hello</p></body>
    """

    private struct Loaded {
        let server: BrowserReplTestHTTPServer
        let webView: WKWebView
        let loads: EmulationTestNavigationDelegate
        let page: WebKitBrowserPage
        func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(server.port)\(path)")! }
    }

    private func loaded() async throws -> Loaded {
        let server = try BrowserReplTestHTTPServer { path, _, _ in
            let title = path.split(separator: "/").last.map(String.init) ?? "root"
            let html = Self.page.replacingOccurrences(of: "<title>parity</title>", with: "<title>\(title)</title>")
            return (200, ["Content-Type": "text/html", "Cache-Control": "no-store"], Data(html.utf8))
        }
        try await server.start()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
        let loads = EmulationTestNavigationDelegate()
        webView.navigationDelegate = loads
        let result = Loaded(server: server, webView: webView, loads: loads, page: WebKitBrowserPage(webView: webView))
        try await load(result, "/first")
        return result
    }

    private func load(_ loaded: Loaded, _ path: String) async throws {
        let finished = loaded.loads.nextFinish()
        loaded.page.load(URLRequest(url: loaded.url(path)))
        try await finished.value
    }

    /// The panel's raw path today (`v2RunJavaScript` without `preferAsync`),
    /// reduced to Sendable text: the canonical value, or the error message the
    /// socket layer reports.
    private func rawEvaluate(_ webView: WKWebView, _ script: String) async -> (value: String, error: String?) {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                continuation.resume(returning: (
                    Self.canonical(value),
                    error.map { BrowserControlService().describeJavaScriptError($0) }
                ))
            }
        }
    }

    /// JSON text with sorted keys, so equal Foundation values compare equal;
    /// `undefined` for nil.
    private static func canonical(_ value: Any?) -> String {
        guard let value else { return "undefined" }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else {
            return "unserializable: \(type(of: value))"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static let resultShapes: [String] = [
        "1 + 2",
        "'text'",
        "true",
        "null",
        "[1, 'two', null, {a: [3]}]",
        "({nested: {deep: true}, n: 1.5})",
        "document.getElementById('p').textContent",
        "undefined",
    ]

    @Test(arguments: resultShapes)
    func pageWorldResultsMatchTheRawWebView(script: String) async throws {
        let loaded = try await loaded()
        defer { loaded.server.stop() }

        let raw = await rawEvaluate(loaded.webView, script)
        let adapted: String
        do {
            adapted = Self.canonical(try await loaded.page.evaluateJavaScript(script, in: .page))
        } catch {
            adapted = "error: " + BrowserControlService().describeJavaScriptError(error)
        }

        #expect(adapted == (raw.error.map { "error: " + $0 } ?? raw.value))
    }

    @Test func exceptionsKeepTheMessageTheSocketLayerReports() async throws {
        let loaded = try await loaded()
        defer { loaded.server.stop() }
        let control = BrowserControlService()
        let script = "throw new Error('parity boom')"

        let raw = await rawEvaluate(loaded.webView, script)
        var adaptedError: (any Error)?
        do {
            _ = try await loaded.page.evaluateJavaScript(script, in: .page)
        } catch {
            adaptedError = error
        }

        let rawMessage = try #require(raw.error)
        let pageError = try #require(adaptedError)
        #expect(control.describeJavaScriptError(pageError) == rawMessage)
        #expect(rawMessage.contains("parity boom"))
    }

    @Test func isolatedWorldsDoNotShareGlobalsWithThePage() async throws {
        let loaded = try await loaded()
        defer { loaded.server.stop() }

        _ = try await loaded.page.evaluateJavaScript("window.__parity = 'page'; true", in: .page)
        _ = try await loaded.page.evaluateJavaScript("window.__parity = 'iso'; true", in: .isolated("cmux-parity"))

        #expect(try await loaded.page.evaluateJavaScript("window.__parity", in: .page) as? String == "page")
        #expect(try await loaded.page.evaluateJavaScript("window.__parity", in: .isolated("cmux-parity")) as? String == "iso")
        // Both worlds see the same DOM.
        #expect(try await loaded.page.evaluateJavaScript("document.title", in: .isolated("cmux-parity")) as? String == "first")
    }

    @Test func asyncFunctionBodiesMatchTheRawWebView() async throws {
        let loaded = try await loaded()
        defer { loaded.server.stop() }
        let body = "await new Promise(r => setTimeout(r, 0)); return [x * 2, label];"

        let raw = try await loaded.webView.callAsyncJavaScript(
            body, arguments: ["x": 21, "label": "ok"], in: nil, contentWorld: .page
        )
        let adapted = try await loaded.page.callAsyncJavaScript(body, arguments: ["x": 21, "label": "ok"], in: .page)

        #expect(Self.canonical(adapted) == Self.canonical(raw))
    }

    @Test func stateMirrorsTheWebViewAcrossHistory() async throws {
        let loaded = try await loaded()
        defer { loaded.server.stop() }
        try await load(loaded, "/second")

        var state = loaded.page.state
        #expect(state.url == loaded.webView.url)
        #expect(state.title == "second")
        #expect(state.canGoBack && !state.canGoForward)
        #expect(state.backURLs == [loaded.url("/first")])

        let back = loaded.loads.nextFinish()
        loaded.page.goBack()
        try await back.value

        state = loaded.page.state
        #expect(state.url == loaded.url("/first"))
        #expect(state.forwardURLs == [loaded.url("/second")])
        #expect(state.canGoForward == loaded.webView.canGoForward)
    }

    @Test func restoreStateRestoresHistoryInAFreshWebView() async throws {
        let loaded = try await loaded()
        defer { loaded.server.stop() }
        try await load(loaded, "/second")

        guard case .webKit(let data) = try #require(loaded.page.exportRestoreState()) else {
            Issue.record("WebKit pages export WebKit restore state")
            return
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let restored = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
        let loads = EmulationTestNavigationDelegate()
        restored.navigationDelegate = loads
        let finished = loads.nextFinish()
        restored.interactionState = data
        try await finished.value

        #expect(restored.url == loaded.url("/second"))
        #expect(restored.backForwardList.backList.map(\.url) == [loaded.url("/first")])
        withExtendedLifetime(loads) {}
    }

    @Test func snapshotsCoverTheVisiblePage() async throws {
        let loaded = try await loaded()
        defer { loaded.server.stop() }

        let image = try await loaded.page.takeSnapshot(rect: nil)

        #expect(image.size == loaded.webView.bounds.size)
    }

    @Test func zoomWritesThroughToTheWebView() async throws {
        let loaded = try await loaded()
        defer { loaded.server.stop() }

        loaded.page.pageZoom = 1.25

        #expect(loaded.webView.pageZoom == 1.25)
        #expect(loaded.page.state.pageZoom == 1.25)
    }
}

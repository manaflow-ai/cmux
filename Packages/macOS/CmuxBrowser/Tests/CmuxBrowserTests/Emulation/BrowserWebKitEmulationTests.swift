import Foundation
import Testing
import WebKit
@testable import CmuxBrowser

@Suite struct BrowserGeolocationOverrideTests {
    @Test(arguments: [
        (91.0, 0.0, 0.0), (-90.5, 0.0, 0.0), (0.0, 180.1, 0.0), (0.0, -181.0, 0.0),
        (0.0, 0.0, -1.0), (Double.nan, 0.0, 0.0), (0.0, Double.infinity, 0.0),
    ])
    func rejectsOutOfRangeValues(latitude: Double, longitude: Double, accuracy: Double) {
        #expect(BrowserGeolocationOverride(latitude: latitude, longitude: longitude, accuracy: accuracy) == nil)
    }

    @Test func acceptsTheRangeEdges() {
        #expect(BrowserGeolocationOverride(latitude: 90, longitude: -180) != nil)
        #expect(BrowserGeolocationOverride(latitude: -90, longitude: 180, accuracy: 25) != nil)
    }
}

/// The WebKit side of `browser.geolocation.set` / `browser.offline.set`
/// against a real page served over HTTP.
@MainActor
@Suite(.serialized)
struct BrowserWebKitEmulationTests {
    private nonisolated static let page = """
    <!doctype html><title>emulation</title>
    <script>
      window.networkEvents = [];
      addEventListener('offline', () => networkEvents.push('offline'));
      addEventListener('online', () => networkEvents.push('online'));
    </script>
    """

    private struct Harness {
        let server: BrowserReplTestHTTPServer
        let webView: WKWebView
        let loads: EmulationTestNavigationDelegate
        let ruleStoreDirectory: URL
        let controller: BrowserWebKitEmulationController
        var origin: String { "http://127.0.0.1:\(server.port)" }
    }

    private func makeHarness() async throws -> Harness {
        let server = try BrowserReplTestHTTPServer { path, _, _ in
            if path.hasPrefix("/data") {
                return (200, ["Content-Type": "text/plain", "Cache-Control": "no-store"], Data("ok".utf8))
            }
            return (200, ["Content-Type": "text/html", "Cache-Control": "no-store"], Data(Self.page.utf8))
        }
        try await server.start()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-emulation-rules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try #require(WKContentRuleListStore(url: directory))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let loads = EmulationTestNavigationDelegate()
        webView.navigationDelegate = loads
        let harness = Harness(
            server: server,
            webView: webView,
            loads: loads,
            ruleStoreDirectory: directory,
            controller: BrowserWebKitEmulationController(ruleListStore: { store })
        )
        try await load(harness, path: "/")
        return harness
    }

    private func tearDown(_ harness: Harness) {
        harness.server.stop()
        try? FileManager.default.removeItem(at: harness.ruleStoreDirectory)
    }

    private func load(_ harness: Harness, path: String, in webView: WKWebView? = nil) async throws {
        let webView = webView ?? harness.webView
        let loads = webView.navigationDelegate as? EmulationTestNavigationDelegate ?? harness.loads
        let finished = loads.nextFinish()
        webView.load(URLRequest(url: try #require(URL(string: harness.origin + path))))
        try await finished.value
    }

    private func value(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, contentWorld: .page)
    }

    private func currentPosition(in webView: WKWebView) async throws -> [String: Double] {
        let result = try await value("""
        return await new Promise((resolve, reject) => {
          navigator.geolocation.getCurrentPosition(
            (p) => resolve({ latitude: p.coords.latitude, longitude: p.coords.longitude, accuracy: p.coords.accuracy }),
            (e) => reject(new Error('geolocation error ' + e.code)),
          );
        });
        """, in: webView)
        let object = try #require(result as? [String: Any])
        return object.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    private func fetchData(in webView: WKWebView) async throws -> String {
        let result = try await value("""
        try { return await (await fetch('/data?' + Math.random())).text(); }
        catch (error) { return 'failed'; }
        """, in: webView)
        return try #require(result as? String)
    }

    @Test func geolocationOverrideAnswersTheLoadedPageAndLaterLoads() async throws {
        let harness = try await makeHarness()
        defer { tearDown(harness) }
        let position = try #require(BrowserGeolocationOverride(latitude: 37.7749, longitude: -122.4194, accuracy: 12))

        try await harness.controller.update(BrowserEmulationOverrides(geolocation: position), on: harness.webView)

        #expect(try await currentPosition(in: harness.webView) == ["latitude": 37.7749, "longitude": -122.4194, "accuracy": 12])
        try await load(harness, path: "/next")
        #expect(try await currentPosition(in: harness.webView) == ["latitude": 37.7749, "longitude": -122.4194, "accuracy": 12])
    }

    @Test func aNewPositionReachesActiveWatchers() async throws {
        let harness = try await makeHarness()
        defer { tearDown(harness) }
        let first = try #require(BrowserGeolocationOverride(latitude: 1, longitude: 2))
        let second = try #require(BrowserGeolocationOverride(latitude: 3, longitude: 4))
        try await harness.controller.update(BrowserEmulationOverrides(geolocation: first), on: harness.webView)
        _ = try await value("""
        window.seen = [];
        window.seenTwice = new Promise((resolve) => {
          window.watchID = navigator.geolocation.watchPosition((p) => {
            seen.push([p.coords.latitude, p.coords.longitude]);
            if (seen.length === 2) resolve(seen);
          });
        });
        return true;
        """, in: harness.webView)

        try await harness.controller.update(BrowserEmulationOverrides(geolocation: second), on: harness.webView)

        let seen = try #require(try await value("return await window.seenTwice;", in: harness.webView) as? [[NSNumber]])
        #expect(seen.map { $0.map(\.doubleValue) } == [[1, 2], [3, 4]])
    }

    @Test func offlineBlocksNetworkLoadsAndReportsTheChange() async throws {
        let harness = try await makeHarness()
        defer { tearDown(harness) }
        #expect(try await fetchData(in: harness.webView) == "ok")

        try await harness.controller.update(BrowserEmulationOverrides(offline: true), on: harness.webView)

        #expect(try await value("return navigator.onLine;", in: harness.webView) as? Bool == false)
        #expect(try await fetchData(in: harness.webView) == "failed")

        try await harness.controller.update(BrowserEmulationOverrides(offline: false), on: harness.webView)

        #expect(try await value("return navigator.onLine;", in: harness.webView) as? Bool == true)
        #expect(try await fetchData(in: harness.webView) == "ok")
        #expect(try await value("return networkEvents;", in: harness.webView) as? [String] == ["offline", "online"])
    }

    @Test func replacementWebViewInheritsTheOverrides() async throws {
        let harness = try await makeHarness()
        defer { tearDown(harness) }
        let position = try #require(BrowserGeolocationOverride(latitude: -33.86, longitude: 151.21))
        try await harness.controller.update(
            BrowserEmulationOverrides(geolocation: position, offline: true),
            on: harness.webView
        )
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let replacement = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let loads = EmulationTestNavigationDelegate()
        replacement.navigationDelegate = loads

        harness.controller.install(on: replacement)
        // Offline blocks the http load itself, so the replacement's document
        // comes from a local string with the same origin.
        let finished = loads.nextFinish()
        replacement.loadHTMLString(Self.page, baseURL: URL(string: harness.origin + "/"))
        try await finished.value

        #expect(try await currentPosition(in: replacement)["latitude"] == -33.86)
        #expect(try await value("return navigator.onLine;", in: replacement) as? Bool == false)
        #expect(try await fetchData(in: replacement) == "failed")
    }

    @Test func resetKeepsReplacementsFreeOfOverrides() async throws {
        let harness = try await makeHarness()
        defer { tearDown(harness) }
        let position = try #require(BrowserGeolocationOverride(latitude: 10, longitude: 20))
        try await harness.controller.update(
            BrowserEmulationOverrides(geolocation: position, offline: true),
            on: harness.webView
        )

        harness.controller.reset()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let replacement = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let loads = EmulationTestNavigationDelegate()
        replacement.navigationDelegate = loads
        harness.controller.install(on: replacement)
        try await load(harness, path: "/", in: replacement)
        _ = loads

        #expect(harness.controller.overrides.isDefault)
        #expect(try await value(
            "return Symbol.for('\(BrowserEmulationOverrides.pageScriptStateKey)') in globalThis;",
            in: replacement
        ) as? Bool == false)
        #expect(try await fetchData(in: replacement) == "ok")
    }

    @Test func defaultOverridesLeaveTheNativeAPIsInPlace() async throws {
        let harness = try await makeHarness()
        defer { tearDown(harness) }
        let nativeOnLine = try await value("return navigator.onLine;", in: harness.webView) as? Bool

        try await harness.controller.update(BrowserEmulationOverrides(), on: harness.webView)

        // The wrappers are installed but defer to WebKit while nothing is set.
        #expect(try await value("return navigator.onLine;", in: harness.webView) as? Bool == nativeOnLine)
        #expect(try await fetchData(in: harness.webView) == "ok")
    }
}

/// Ends each pending waiter when the main-frame load finishes or fails.
@MainActor
final class EmulationTestNavigationDelegate: NSObject, WKNavigationDelegate {
    private var finishers: [AsyncThrowingStream<Void, any Error>.Continuation] = []

    /// Registers before the load starts, so a fast load cannot be missed.
    func nextFinish() -> Task<Void, any Error> {
        let (stream, continuation) = AsyncThrowingStream<Void, any Error>.makeStream()
        finishers.append(continuation)
        return Task { for try await _ in stream {} }
    }

    private func finish(_ error: (any Error)?) {
        let pending = finishers
        finishers.removeAll()
        pending.forEach { $0.finish(throwing: error) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(error)
    }
}

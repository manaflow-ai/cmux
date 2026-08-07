import AppKit
import CmuxFoundation
import Foundation
import Testing
import WebKit

@testable import CmuxSidebar

/// An explicit reload of a remote sidebar fetches the server's current bytes.
///
/// Counting issued loads proves the host asked for a reload; it does not prove the user sees a
/// different page. `WKWebView.load(URLRequest)` uses the default cache policy, so a second load of
/// the same URL can be served from the URL cache and repaint the identical stale document —
/// indistinguishable from the load never happening, which is the complaint `cmux sidebar reload`
/// exists to answer. These tests run against a real loopback server whose body changes between
/// requests, because that is the only setup where the two outcomes look different.
@Suite("CustomSidebarWebView remote reload", .serialized)
@MainActor
struct CustomSidebarWebRemoteReloadTests {
    private func makeCoordinator() -> (CustomSidebarWebView.Coordinator, WKWebView) {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        let container = CustomSidebarWebContainerView(webView: webView)
        let coordinator = CustomSidebarWebView.Coordinator()
        coordinator.container = container
        coordinator.attach(registry: CustomSidebarFocusHandlerRegistrySpy(), webView: webView)
        return (coordinator, webView)
    }

    /// Spins the main run loop until the page reports `marker`, or gives up.
    ///
    /// Polling rather than observing `isLoading`: the question is whether the *document* changed,
    /// and a cache-served load finishes just as cleanly as a network one.
    private func waitForBody(
        containing marker: String,
        in webView: WKWebView,
        timeout: TimeInterval = 10
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = try? await webView.evaluateJavaScript("document.body.innerText") as? String
            if let text = text ?? nil, text.contains(marker) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test("an explicit reload shows the server's new bytes rather than the cached document")
    func explicitReloadBypassesCache() async throws {
        let server = LoopbackHTTPServer(body: "<html><body>first</body></html>")
        guard let origin = server.start() else {
            Issue.record("loopback server did not start")
            return
        }
        defer { server.stop() }

        let (coordinator, webView) = makeCoordinator()
        let source = CustomSidebarWebSource.remote(origin)
        coordinator.apply(source: source, focusWorkspace: nil, into: webView)
        #expect(await waitForBody(containing: "first", in: webView))

        server.body = "<html><body>second</body></html>"
        coordinator.apply(
            source: source,
            reloadToken: CustomSidebarWebReloadToken.initial.bumped(),
            focusWorkspace: nil,
            into: webView
        )

        #expect(await waitForBody(containing: "second", in: webView))
        // Exactly two: the initial load and the reload. A cache hit would leave this at one, and
        // the document assertion above would have timed out on the stale body.
        #expect(server.requestCount == 2)
    }

    @Test("repeated reloads keep reaching the server")
    func repeatedReloadsKeepReachingTheServer() async throws {
        let server = LoopbackHTTPServer(body: "<html><body>v1</body></html>")
        guard let origin = server.start() else {
            Issue.record("loopback server did not start")
            return
        }
        defer { server.stop() }

        let (coordinator, webView) = makeCoordinator()
        let source = CustomSidebarWebSource.remote(origin)
        var token = CustomSidebarWebReloadToken.initial
        coordinator.apply(source: source, reloadToken: token, focusWorkspace: nil, into: webView)
        #expect(await waitForBody(containing: "v1", in: webView))

        for version in 2...3 {
            server.body = "<html><body>v\(version)</body></html>"
            token = token.bumped()
            coordinator.apply(source: source, reloadToken: token, focusWorkspace: nil, into: webView)
            #expect(await waitForBody(containing: "v\(version)", in: webView))
        }
    }

    // A steady-state update carries no reload intent, so it must not re-fetch: the page keeps its
    // scroll position and the server sees no traffic.
    @Test("an update with no reload intent does not re-fetch")
    func steadyStateUpdateDoesNotRefetch() async throws {
        let server = LoopbackHTTPServer(body: "<html><body>only</body></html>")
        guard let origin = server.start() else {
            Issue.record("loopback server did not start")
            return
        }
        defer { server.stop() }

        let (coordinator, webView) = makeCoordinator()
        let source = CustomSidebarWebSource.remote(origin)
        coordinator.apply(source: source, focusWorkspace: nil, into: webView)
        #expect(await waitForBody(containing: "only", in: webView))
        let afterFirst = server.requestCount

        for _ in 0..<3 {
            coordinator.apply(source: source, focusWorkspace: nil, into: webView)
        }
        try? await Task.sleep(for: .milliseconds(300))

        #expect(server.requestCount == afterFirst)
    }
}

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
/// the same URL can be served from the URL cache and repaint the identical stale document,
/// indistinguishable from the load never happening, which is the complaint `cmux sidebar reload`
/// exists to answer. These tests run against a real loopback server whose body changes between
/// requests, because that is the only setup where the two outcomes look different.
@Suite("CustomSidebarWebView remote reload", .serialized)
@MainActor
struct CustomSidebarWebRemoteReloadTests {
    private struct NavigationFailure: Error, CustomStringConvertible, Sendable {
        let description: String
    }

    private final class NavigationRecorder: NSObject, WKNavigationDelegate {
        private let events: AsyncStream<Result<Void, NavigationFailure>>
        private let continuation: AsyncStream<Result<Void, NavigationFailure>>.Continuation

        override init() {
            (events, continuation) = AsyncStream.makeStream()
            super.init()
        }

        func nextCompletion() async throws {
            var iterator = events.makeAsyncIterator()
            guard let event = await iterator.next() else {
                throw NavigationFailure(description: "navigation event stream ended before completion")
            }
            try event.get()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation.yield(.success(()))
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: any Error
        ) {
            continuation.yield(.failure(NavigationFailure(description: error.localizedDescription)))
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            continuation.yield(.failure(NavigationFailure(description: error.localizedDescription)))
        }
    }

    private func makeCoordinator() -> (
        CustomSidebarWebView.Coordinator,
        WKWebView,
        NavigationRecorder
    ) {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        let container = CustomSidebarWebContainerView(webView: webView)
        let coordinator = CustomSidebarWebView.Coordinator()
        coordinator.container = container
        coordinator.attach(registry: CustomSidebarFocusHandlerRegistrySpy(), webView: webView)
        let navigationRecorder = NavigationRecorder()
        webView.navigationDelegate = navigationRecorder
        return (coordinator, webView, navigationRecorder)
    }

    /// Waits for WebKit's navigation completion callback, then reads the committed document once.
    ///
    /// The callback is the deterministic boundary the old polling sleep was approximating: after
    /// `didFinish`, scripts and the document body for that navigation are available to inspect.
    private func completedBody(
        containing marker: String,
        in webView: WKWebView,
        recorder: NavigationRecorder
    ) async throws -> Bool {
        try await recorder.nextCompletion()
        let text = try await webView.evaluateJavaScript("document.body.innerText") as? String
        return text?.contains(marker) == true
    }

    @Test("an explicit reload shows the server's new bytes rather than the cached document")
    func explicitReloadBypassesCache() async throws {
        let (server, origin) = try LoopbackHTTPServer.started(
            body: "<html><body>first</body></html>"
        )
        defer { server.stop() }

        let (coordinator, webView, recorder) = makeCoordinator()
        let source = CustomSidebarWebSource.remote(origin)
        coordinator.apply(source: source, focusWorkspace: nil, into: webView)
        #expect(try await completedBody(containing: "first", in: webView, recorder: recorder))

        server.body = "<html><body>second</body></html>"
        coordinator.apply(
            source: source,
            reloadToken: CustomSidebarWebReloadToken.initial.bumped(),
            focusWorkspace: nil,
            into: webView
        )

        #expect(try await completedBody(containing: "second", in: webView, recorder: recorder))
        // Exactly two: the initial load and the reload. A cache hit would leave this at one, and
        // the document assertion above would see the stale body.
        #expect(server.requestCount == 2)
    }

    @Test("repeated reloads keep reaching the server")
    func repeatedReloadsKeepReachingTheServer() async throws {
        let (server, origin) = try LoopbackHTTPServer.started(body: "<html><body>v1</body></html>")
        defer { server.stop() }

        let (coordinator, webView, recorder) = makeCoordinator()
        let source = CustomSidebarWebSource.remote(origin)
        var token = CustomSidebarWebReloadToken.initial
        coordinator.apply(source: source, reloadToken: token, focusWorkspace: nil, into: webView)
        #expect(try await completedBody(containing: "v1", in: webView, recorder: recorder))

        for version in 2...3 {
            server.body = "<html><body>v\(version)</body></html>"
            token = token.bumped()
            coordinator.apply(source: source, reloadToken: token, focusWorkspace: nil, into: webView)
            #expect(try await completedBody(containing: "v\(version)", in: webView, recorder: recorder))
        }
    }

    // A steady-state update carries no reload intent, so it must not re-fetch: the page keeps its
    // scroll position and the server sees no traffic.
    //
    // "Nothing happened" cannot be waited for directly, so it is bracketed by something that can. A
    // reload is issued after the steady-state updates, against the same server; when its navigation
    // completes, every request those updates could have made has already been counted, because the
    // server answers in order on one queue. The count between the two known points is then exact.
    @Test("an update with no reload intent does not re-fetch")
    func steadyStateUpdateDoesNotRefetch() async throws {
        let (server, origin) = try LoopbackHTTPServer.started(body: "<html><body>only</body></html>")
        defer { server.stop() }

        let (coordinator, webView, recorder) = makeCoordinator()
        let source = CustomSidebarWebSource.remote(origin)
        coordinator.apply(source: source, focusWorkspace: nil, into: webView)
        #expect(try await completedBody(containing: "only", in: webView, recorder: recorder))
        let afterFirst = server.requestCount

        for _ in 0..<3 {
            coordinator.apply(source: source, focusWorkspace: nil, into: webView)
        }

        // The barrier: a real reload, whose completion proves the server has finished with anything
        // the updates above sent it.
        server.body = "<html><body>barrier</body></html>"
        coordinator.apply(
            source: source,
            reloadToken: CustomSidebarWebReloadToken.initial.bumped(),
            focusWorkspace: nil,
            into: webView
        )
        #expect(try await completedBody(containing: "barrier", in: webView, recorder: recorder))

        // Exactly one request since the initial load: the barrier's. The three updates in between
        // sent none.
        #expect(server.requestCount == afterFirst + 1)
    }
}

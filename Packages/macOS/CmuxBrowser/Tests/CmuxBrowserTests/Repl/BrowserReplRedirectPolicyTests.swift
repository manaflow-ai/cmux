import Foundation
import Testing
import WebKit

@testable import CmuxBrowser

/// The domain policy cancels a blocked main-frame page in the navigation
/// delegate's action decision (`BrowserReplNavigationGuard.cancels`), not
/// in its response decision. That holds for HTTP redirects only because
/// WebKit asks the action decision again for every redirect hop, with the
/// hop's URL and the main frame as its target, before it requests the hop.
/// These tests prove that with a real web view and a loopback server: a
/// cancel there, decided by the policy, stops the redirect before the
/// blocked host is asked for anything, so no response of it is decided,
/// committed or run.
@MainActor
@Suite("Browser REPL redirects under the domain policy", .serialized)
struct BrowserReplRedirectPolicyTests {
    @Test("WebKit asks the action decision for each main-frame redirect hop, and the policy's cancel there stops it")
    func redirectHopIsDecidedAsANavigationAction() async throws {
        let paths = Paths()
        let server = try BrowserReplTestHTTPServer { path, _, port in
            paths.append(path)
            if path.hasPrefix("/hop") {
                // Allowed host, then a second hop to the blocked one.
                return (302, ["Location": "http://127.0.0.1:\(port)/redirect"], Data())
            }
            if path.hasPrefix("/redirect") {
                return (302, ["Location": "http://localhost:\(port)/blocked"], Data())
            }
            return (200, ["Content-Type": "text/html"], Data("<script>fetch('/ran')</script>".utf8))
        }
        try await server.start()
        defer { server.stop() }

        var policy = BrowserReplDomainPolicy()
        policy.prohibited = [try BrowserReplDomainPattern.parse("localhost", title: "session.prohibitedDomains")]
        let delegate = PolicyDelegate(policy: policy)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        webView.navigationDelegate = delegate
        for start in ["/redirect", "/hop"] {
            webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)\(start)")!))
            try await delegate.waitForEnd()
        }

        let hops = delegate.actions.filter { $0.url.hasPrefix("http://localhost:") }
        #expect(hops.count == 2, "WebKit did not ask the action decision for each redirect to the blocked host: \(delegate.actions)")
        #expect(hops.allSatisfy { $0.mainFrame && $0.cancelled }, "a redirect hop was not a cancelled main-frame action: \(hops)")
        #expect(!paths.all.contains("/blocked"), "the blocked host was requested")
        #expect(!paths.all.contains("/ran"), "the blocked page ran")
        #expect(!delegate.responses.contains { $0.hasPrefix("http://localhost:") }, "a response of the blocked host was decided: \(delegate.responses)")
        #expect(!delegate.committed.contains { $0.hasPrefix("http://localhost:") }, "the blocked page committed")
    }

    final class Paths: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        var all: [String] { lock.withLock { recorded } }
        func append(_ path: String) { lock.withLock { recorded.append(path) } }
    }
}

/// Decides each main-frame navigation action by the policy, as the
/// browser's navigation delegate does through `BrowserReplNavigationGuard`.
@MainActor
private final class PolicyDelegate: NSObject, WKNavigationDelegate {
    struct Action { let url: String; let mainFrame: Bool; let cancelled: Bool }

    let policy: BrowserReplDomainPolicy
    private(set) var actions: [Action] = []
    private(set) var responses: [String] = []
    private(set) var committed: [String] = []
    private var ended = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(policy: BrowserReplDomainPolicy) { self.policy = policy }

    func waitForEnd() async throws {
        if !ended { await withCheckedContinuation { continuation = $0 } }
        ended = false
    }

    private func end() {
        ended = true
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let mainFrame = navigationAction.targetFrame?.isMainFrame == true
        let cancel = mainFrame && navigationAction.request.url.flatMap { policy.navigationBlockReason($0, initiator: nil) } != nil
        actions.append(Action(url: navigationAction.request.url?.absoluteString ?? "", mainFrame: mainFrame, cancelled: cancel))
        decisionHandler(cancel ? .cancel : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        responses.append(navigationResponse.response.url?.absoluteString ?? "")
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        committed.append(webView.url?.absoluteString ?? "")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { end() }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { end() }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { end() }
}

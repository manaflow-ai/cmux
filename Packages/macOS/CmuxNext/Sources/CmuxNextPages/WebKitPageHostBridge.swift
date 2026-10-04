import Foundation
import os
public import WebKit

/// ``PageHostBridge`` for a WKWebView: a `WKScriptMessageHandlerWithReply` in the page world.
public final class WebKitPageHostBridge: PageHostBridge {
    public let engine = PageHostEngine.webKit
    private weak var webView: WKWebView?
    private var installed = false

    public init(webView: WKWebView) {
        self.webView = webView
    }

    public func install(_ handler: @escaping PageHostHandler) {
        guard let webView, !installed else { return }
        installed = true
        webView.configuration.userContentController.addScriptMessageHandler(
            WebKitPageHostReceiver(webView: webView, handler: handler), contentWorld: .page, name: PageHostTrust.handlerName)
    }

    /// The last error WebKit reported for an ``evaluate(_:)`` (diagnostics and tests).
    public private(set) var lastEvaluateError: String?
    /// Scripts sent and scripts WebKit finished (diagnostics and tests).
    public private(set) var evaluations = (sent: 0, finished: 0)

    public func evaluate(_ script: String) {
        guard let webView else { return }
        evaluations.sent += 1
        webView.evaluateJavaScript(script) { [weak self] _, error in
            MainActor.assumeIsolated {
                self?.evaluations.finished += 1
                if let error { self?.lastEvaluateError = String(describing: error) }
            }
        }
    }

    public func uninstall() {
        guard installed else { return }
        installed = false
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: PageHostTrust.handlerName, contentWorld: .page)
    }
}

/// The user content controller retains its handlers, so this holds the web view weakly.
private final class WebKitPageHostReceiver: NSObject, WKScriptMessageHandlerWithReply {
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "page-host.webkit")
    private weak var webView: WKWebView?
    private let handler: PageHostHandler

    init(webView: WKWebView, handler: @escaping PageHostHandler) {
        self.webView = webView
        self.handler = handler
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        // A web view that shares this configuration is another page.
        guard let webView, message.webView === webView else {
            logger.error("page host message from another web view refused")
            return (nil, "untrusted frame")
        }
        let request = PageHostMessage(
            frameURL: message.frameInfo.request.url, isMainFrame: message.frameInfo.isMainFrame, body: message.body)
        return (await handler(request), nil)
    }
}

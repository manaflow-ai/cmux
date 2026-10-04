import Foundation
import os
public import WebKit

/// ``PaneHostBridge`` for a WKWebView: a `WKScriptMessageHandlerWithReply`
/// named `name` in the page world. The page posts with
/// `window.webkit.messageHandlers.<name>.postMessage(body)`.
public final class WebKitPaneHostBridge: PaneHostBridge {
    public let engine = PaneHostEngine.webKit
    public let name: String
    private weak var webView: WKWebView?
    private var installed = false

    public init(webView: WKWebView, name: String = AgentPaneRequest.handlerName) {
        self.webView = webView
        self.name = name
    }

    public func install(_ handler: @escaping PaneHostHandler) async throws {
        attach(handler)
    }

    /// ``install(_:)`` without suspending, for a caller that loads the page
    /// right after (a view's initializer).
    public func attach(_ handler: @escaping PaneHostHandler) {
        guard let webView, !installed else { return }
        installed = true
        webView.configuration.userContentController.addScriptMessageHandler(
            WebKitPaneHostReceiver(webView: webView, handler: handler), contentWorld: .page, name: name)
    }

    public func evaluate(_ script: String) {
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    public func uninstall() {
        guard installed else { return }
        installed = false
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: name, contentWorld: .page)
    }
}

/// The user content controller retains its handlers, so this holds the web
/// view weakly.
private final class WebKitPaneHostReceiver: NSObject, WKScriptMessageHandlerWithReply {
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "pane-host.webkit")
    private weak var webView: WKWebView?
    private let handler: PaneHostHandler

    init(webView: WKWebView, handler: @escaping PaneHostHandler) {
        self.webView = webView
        self.handler = handler
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        // A web view sharing this configuration is another pane.
        guard let webView, message.webView === webView else {
            logger.error("pane host message from another web view refused")
            return (AgentPaneReply.failure(code: "untrusted_frame", message: "Untrusted frame"), nil)
        }
        let request = PaneHostMessage(
            frameURL: message.frameInfo.request.url, isMainFrame: message.frameInfo.isMainFrame, body: message.body)
        return (await handler(request), nil)
    }
}

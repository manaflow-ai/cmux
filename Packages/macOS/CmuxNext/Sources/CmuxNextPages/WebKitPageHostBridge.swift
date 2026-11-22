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

    public func evaluate(_ script: String) {
        webView?.evaluateJavaScript(script, completionHandler: nil)
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

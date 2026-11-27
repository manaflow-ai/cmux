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

    /// Runs `script` in the loaded document. Nothing runs before the first load: WebKit launches a
    /// web content process to run script in a view that never loaded (an about:blank the load
    /// replaces anyway), so every Chromium page's hidden WebKit view held an idle process (WebKit
    /// logs about 32 MB for an idle one) that WebKit's GPU process served and that
    /// WebKit ended, in all of them at once, when that GPU process stopped answering (Leo's Mac,
    /// 2026-11-01: 19 chats).
    public func evaluate(_ script: String) {
        guard let webView, webView.url != nil else { return }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Runs the one fixed ``PageRouter/receiveBody`` with the envelope's text as its argument, never
    /// a new script text per push (RFD 0062). It goes to the web process on the same queue as
    /// ``evaluate(_:)``, so pushes and scripts keep their order. Nothing runs before the first load.
    public func receive(_ envelopeText: String) {
        evaluate(PageRouter.receiveBody, argument: "envelope", text: envelopeText)
    }

    /// `callAsyncJavaScript` of the fixed `body` with `text` as its argument (RFD 0062).
    public func evaluate(_ body: String, argument name: String, text: String) {
        guard let webView, webView.url != nil else { return }
        webView.callAsyncJavaScript(body, arguments: [name: text], in: nil, in: .page, completionHandler: nil)
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

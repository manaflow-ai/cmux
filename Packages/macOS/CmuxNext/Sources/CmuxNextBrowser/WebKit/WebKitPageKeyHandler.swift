import WebKit

/// A letter a WebKit page left alone outside a text field (``BrowserPageKeyReportScript``), as
/// Chromium reports one: the host runs the single-key action bound to it (`f`, `j`, `gg`).
final class WebKitPageKeyHandler: NSObject, WKScriptMessageHandler {
    static let channel = BrowserPageKeyReportScript.channel
    static let world = BrowserPageKeyReportScript.world
    private weak var tab: WebKitTab?

    private init(tab: WebKitTab) { self.tab = tab }

    /// The controller keeps the handler; the handler keeps the tab weakly.
    static func install(on tab: WebKitTab, into controller: WKUserContentController) {
        let world = WKContentWorld.world(name: world)
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        controller.add(WebKitPageKeyHandler(tab: tab), contentWorld: world, name: channel)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Untrusted page data: one ASCII letter, from a view that has the keyboard.
        guard let tab, (tab.webView as? WebKitWebView)?.hasKeyboardFocus == true, let payload = message.body as? String,
              let key = BrowserPageKey(reported: payload) else { return }
        tab.emit(.unhandledKey(key))
    }

    static let script = BrowserPageKeyReportScript.source(
        post: "window.webkit.messageHandlers.\(channel).postMessage(key)",
        ready: "!!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(channel))")
}

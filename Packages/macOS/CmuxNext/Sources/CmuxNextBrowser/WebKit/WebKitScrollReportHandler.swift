import WebKit

/// Where a WebKit page's main frame settled after scrolling (`BrowserScrollReportScript`, in its
/// own content world), into the tab's state (`BrowserNavigationEvent.pageScrolled`).
final class WebKitScrollReportHandler: NSObject, WKScriptMessageHandler {
    static let channel = BrowserScrollReportScript.channel
    static let world = BrowserScrollReportScript.world
    private weak var tab: WebKitTab?

    private init(tab: WebKitTab) { self.tab = tab }

    /// The controller keeps the handler; the handler keeps the tab weakly.
    static func install(on tab: WebKitTab, into controller: WKUserContentController) {
        let world = WKContentWorld.world(name: world)
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        controller.add(WebKitScrollReportHandler(tab: tab), contentWorld: world, name: channel)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Untrusted page data: only a main frame's whole, bounded position counts.
        guard message.frameInfo.isMainFrame, let number = message.body as? NSNumber,
              let y = BrowserScrollReport.y(fromPayload: number.stringValue) else { return }
        tab?.apply(.pageScrolled(y))
    }

    static let script = BrowserScrollReportScript.source(
        post: "window.webkit.messageHandlers.\(channel).postMessage(y)",
        ready: "!!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(channel))")
}

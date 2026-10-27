import WebKit

/// The main frame's first contentful paint in a WebKit page (`BrowserFirstPaintScript`, in its own
/// content world). Ends a wake's stand-in picture (`WebKitTab.pageDidPaint`).
final class WebKitFirstPaintHandler: NSObject, WKScriptMessageHandler {
    static let channel = BrowserFirstPaintScript.channel
    static let world = BrowserFirstPaintScript.world
    private weak var tab: WebKitTab?

    private init(tab: WebKitTab) { self.tab = tab }

    /// The controller keeps the handler; the handler keeps the tab weakly.
    static func install(on tab: WebKitTab, into controller: WKUserContentController) {
        let world = WKContentWorld.world(name: world)
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        controller.add(WebKitFirstPaintHandler(tab: tab), contentWorld: world, name: channel)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        tab?.pageDidPaint()
    }

    static let script = BrowserFirstPaintScript.source(
        post: "window.webkit.messageHandlers.\(channel).postMessage(report)",
        ready: "!!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(channel))")
}

/// A new WebKit tab's first content frame (`create.tab`): the main frame's first contentful paint above, or its
/// load end with nothing painted (`webView(_:didFinish:)`).
extension WebKitTab: BrowserFirstContentFrameReporting {
    /// A session-local tab made with no address loads nothing.
    public var loadsDocument: Bool { webView.url != nil || webView.isLoading }

    public func whenFirstContentFrame(_ body: @escaping @MainActor (_ shown: Bool) -> Void) {
        firstContentFrame.add(body)
    }
}

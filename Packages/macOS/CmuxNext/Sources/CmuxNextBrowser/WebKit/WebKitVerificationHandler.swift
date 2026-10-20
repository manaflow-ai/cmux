import WebKit

/// The email verification detector in a WebKit page (`VerificationPageScripts`): its own content
/// world, top frame only, so a page cannot call the handler or fake a report. A report emits
/// `.verificationPageWaiting` once per document.
final class WebKitVerificationHandler: NSObject, WKScriptMessageHandler {
    private weak var tab: WebKitTab?

    private init(tab: WebKitTab) { self.tab = tab }

    /// The controller keeps the handler; the handler keeps the tab weakly.
    static func install(on tab: WebKitTab, into controller: WKUserContentController) {
        let world = WKContentWorld.world(name: VerificationPageScripts.world)
        let post = "window.webkit.messageHandlers.\(VerificationPageScripts.channel).postMessage(report)"
        controller.addUserScript(WKUserScript(source: VerificationPageScripts.detectorScript(post: post), injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: world))
        controller.add(WebKitVerificationHandler(tab: tab), contentWorld: world, name: VerificationPageScripts.channel)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, VerificationPageScripts.isWaitingReport(message.body) else { return }
        tab?.emit(.verificationPageWaiting)
    }
}

import WebKit

/// The media hub's scripts in a WebKit page (`BrowserMediaState+Scripts`):
/// the observer in its own content world (a page cannot call the handler or
/// replace the listeners), posting to `cmuxMedia`, whose reports this
/// handler applies to the tab; the action recorder in the page's world.
final class WebKitMediaHandler: NSObject, WKScriptMessageHandler {
    private weak var tab: WebKitTab?

    private init(tab: WebKitTab) { self.tab = tab }

    /// The controller keeps the handler; the handler keeps the tab weakly.
    static func install(on tab: WebKitTab, into controller: WKUserContentController) {
        let world = WKContentWorld.world(name: BrowserMediaState.world)
        let observer = BrowserMediaState.observerScript(post: "window.webkit.messageHandlers.\(BrowserMediaState.channel).postMessage(report)")
        controller.addUserScript(WKUserScript(source: observer, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        controller.addUserScript(WKUserScript(source: BrowserMediaState.actionsScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: .page))
        controller.add(WebKitMediaHandler(tab: tab), contentWorld: world, name: BrowserMediaState.channel)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let media = BrowserMediaState.report(message.body) else { return }
        tab?.apply(.mediaChanged(media))
        tab?.keepAudioMute(after: media)
    }
}

extension WebKitTab: BrowserAudioMuting {
    public func setAudioMuted(_ muted: Bool) {
        apply(.audioMutedChanged(muted))
        Task { await media(.muteTab(muted)) }
    }
}

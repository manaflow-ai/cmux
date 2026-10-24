import WebKit

/// The main frame's first contentful paint in a WebKit page (Paint Timing, `first-contentful-paint`),
/// from a script in its own content world: WebKit reports no first paint to the app, and its
/// `didFinish` comes at the end of the load, long after a heavy page is on screen. Ends a wake's
/// stand-in picture (`WebKitTab.pageDidPaint`).
final class WebKitFirstPaintHandler: NSObject, WKScriptMessageHandler {
    static let channel = "cmuxFirstPaint"
    static let world = "cmuxFirstPaint"
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

    /// One report per document, buffered so a paint before the observer starts still counts.
    static let script = """
    (() => {
      const channel = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(channel);
      if (!channel || typeof PerformanceObserver !== 'function') return;
      try {
        const observer = new PerformanceObserver((list) => {
          if (!list.getEntriesByName('first-contentful-paint').length) return;
          observer.disconnect();
          channel.postMessage(true);
        });
        observer.observe({ type: 'paint', buffered: true });
      } catch (_) {}
    })();
    """
}

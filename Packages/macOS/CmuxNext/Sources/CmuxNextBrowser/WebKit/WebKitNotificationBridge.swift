import WebKit

/// Web notifications in WebKit tabs. WebKit shows none itself (it hands them
/// to a private delegate cmux does not set), so a script in the page's world
/// wraps `Notification`: each one the page makes posts to `cmuxWebNotification`,
/// and the tab asks its host to show a banner when the frame's site has
/// notifications allowed (the prompt bar's stored answer). A page that
/// posts without permission gets nothing, and so does a frame (Chrome
/// refuses cross-origin frames; a banner names the frame's site but opens the
/// embedding tab). A banner click dispatches `click` on the page's
/// notification object; ids are unique per document, so a banner from an
/// earlier document reaches nothing.
final class WebKitNotificationBridge: NSObject, WKScriptMessageHandler {
    static let channel = "cmuxWebNotification"
    private weak var tab: WebKitTab?

    private init(tab: WebKitTab) { self.tab = tab }

    /// The controller keeps the bridge; the bridge keeps the tab weakly.
    static func install(on tab: WebKitTab, into controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        controller.add(WebKitNotificationBridge(tab: tab), contentWorld: .page, name: channel)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let tab, let body = message.body as? [String: Any], let id = body["id"] as? String,
              let title = body["title"] as? String else { return }
        let text = body["body"] as? String ?? ""
        let frame = message.frameInfo
        guard frame.isMainFrame else { return }
        let origin = WebKitTab.displayOrigin(frame.securityOrigin)
        let store = tab.sitePermissions
        // main-hop-allow: whenLoaded is the permission store's main-actor wait for its one file read (at once once read); the notice is handed to the tab in its resume
        Task { @MainActor [weak tab] in
            await store.whenLoaded()
            guard let tab, store.setting(.notifications, for: origin) == .allow else { return }
            let site = URL(string: origin).flatMap { url in url.host().map { host in url.port.map { "\(host):\($0)" } ?? host } } ?? origin
            tab.emit(.webNotification(BrowserWebNotification(title: title, body: text, site: site) { [weak tab] in
                tab?.webView.callAsyncJavaScript("window.__cmuxWebNotificationClick?.(id)", arguments: ["id": id], in: frame,
                                                 in: .page, completionHandler: nil)
            }))
        }
    }

    /// Wraps the page's `Notification` (its statics, `permission` and
    /// `requestPermission`, are inherited); keeps the last 32 for clicks.
    static let script = """
    (() => {
      const Native = window.Notification;
      const channel = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(channel);
      if (typeof Native !== "function" || !channel) return;
      const shown = new Map();
      const doc = Math.random().toString(36).slice(2);
      let next = 0;
      class Notification extends Native {
        constructor(title, options) {
          super(title, options);
          const id = doc + "-" + (++next);
          shown.set(id, this);
          if (shown.size > 32) shown.delete(shown.keys().next().value);
          const body = options && options.body != null ? String(options.body) : "";
          channel.postMessage({ id, title: String(title), body });
        }
      }
      Object.defineProperty(window, "Notification", { value: Notification, writable: true, configurable: true });
      Object.defineProperty(window, "__cmuxWebNotificationClick", {
        value: (id) => { const n = shown.get(String(id)); if (n) n.dispatchEvent(new Event("click")); },
      });
    })();
    """
}

import Foundation

/// Web notifications in Chromium tabs. Chromium shows none itself (`CEFSwitches` turns its macOS
/// bridge off), so, as in WebKit tabs (`WebKitNotificationBridge`), a page-world script wraps
/// `Notification` and every one the page makes is reported; the tab shows a cmux banner when the
/// page's site has notifications allowed (the prompt bar's stored answer, `CEFPermissionPrompts`).
/// A Chromium page world cannot post to cmux, so the page script hands the notification over a
/// `<html>` attribute and an event (DOM attributes cross worlds) to a relay in the media world,
/// which posts it on ``channel`` and removes the attribute. Main frame only: Chrome refuses
/// cross-origin frames, and a banner opens the embedding tab.
nonisolated enum BrowserWebNotificationScript {
    /// The binding (DevTools path) or page channel (fork API 29) the relay posts on, in the media
    /// world (`BrowserMediaState.world`).
    static let channel = "cmuxWebNotification"
    /// The `<html>` attribute the page script writes one notification's JSON to.
    static let attribute = "data-cmux-web-notification"
    /// The event the page script sends after writing ``attribute``.
    static let event = "cmux-web-notification"
    /// The longest title or body a banner takes; the rest is cut.
    static let maxTextLength = 1024

    /// One notification the page made: untrusted, from the page.
    struct Posted: Equatable, Sendable {
        /// Unique per document; the banner's click names it (``clickScript(id:)``).
        let id: String
        let title: String
        let body: String
    }

    /// The page-world wrapper: `Notification`'s statics (`permission`, `requestPermission`) are
    /// inherited; each notification made is reported once; the last 32 are kept for clicks.
    static let pageScript = """
    (() => {
      const Native = window.Notification;
      if (typeof Native !== "function" || Native.__cmuxWrapped) return;
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
          const root = document.documentElement;
          if (!root) return;
          root.setAttribute("\(attribute)", JSON.stringify({ id, title: String(title), body }));
          document.dispatchEvent(new Event("\(event)"));
        }
      }
      Object.defineProperty(Notification, "__cmuxWrapped", { value: true });
      Object.defineProperty(window, "Notification", { value: Notification, writable: true, configurable: true });
      Object.defineProperty(window, "__cmuxWebNotificationClick", {
        value: (id) => { const n = shown.get(String(id)); if (n) n.dispatchEvent(new Event("click")); },
      });
    })();
    """

    /// The media-world relay: takes the notification off ``attribute`` when ``event`` comes (the
    /// event is dispatched synchronously, so each notification is read before the next one writes)
    /// and posts it: `post` is the statement that sends `report`, `ready` the expression that says it can.
    static func relayScript(post: String, ready: String) -> String {
        """
        (() => {
          document.addEventListener("\(event)", () => {
            const root = document.documentElement;
            const report = root && root.getAttribute("\(attribute)");
            if (!report) return;
            root.removeAttribute("\(attribute)");
            let tries = 0;
            const send = () => {
              if (\(ready)) { \(post); return; }
              if (++tries < 40) setTimeout(send, 50);
            };
            send();
          }, true);
        })();
        """
    }

    /// The page-world call that dispatches `click` on the notification `id` names.
    static func clickScript(id: String) -> String {
        let quoted = (try? JSONSerialization.data(withJSONObject: [id], options: [.fragmentsAllowed]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return "window.__cmuxWebNotificationClick?.(\(quoted)[0])"
    }

    /// One reported notification (a binding payload or a page channel post), nil when it is not
    /// `{id, title, body}` with an id under 64 characters; title and body are cut at ``maxTextLength``.
    static func posted(json payload: String) -> Posted? {
        guard let data = payload.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty, id.count <= 64,
              let title = object["title"] as? String else { return nil }
        let body = object["body"] as? String ?? ""
        return Posted(id: id, title: String(title.prefix(maxTextLength)), body: String(body.prefix(maxTextLength)))
    }

    /// The site a banner names for `origin` ("example.com", "127.0.0.1:8080"), as WebKit tabs do.
    static func site(of origin: String) -> String {
        URL(string: origin).flatMap { url in url.host().map { host in url.port.map { "\(host):\($0)" } ?? host } } ?? origin
    }
}

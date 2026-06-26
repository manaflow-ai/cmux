import WebKit

extension CmuxWebView {
    static func subframeDownloadIntentScript(token: String, handlerName: String) -> WKUserScript {
        WKUserScript(
            source: subframeDownloadIntentScriptSource(token: token, handlerName: handlerName),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    private static func subframeDownloadIntentScriptSource(token: String, handlerName: String) -> String {
        """
    (() => {
      try {
        let isMainFrame = false;
        try {
          isMainFrame = window.top === window;
        } catch (_) {
          isMainFrame = false;
        }
        if (isMainFrame) return true;

        const bridgeToken = "\(token)";
        const handler = (() => {
          try {
            return window.webkit?.messageHandlers?.\(handlerName) ?? null;
          } catch (_) {
            return null;
          }
        })();
        if (!handler) return false;
        const postMessage = handler.postMessage.bind(handler);
        let lastIntentPostMs = 0;

        const reserveIntentPost = () => {
          const now = Date.now();
          if (now - lastIntentPostMs < 500) return false;
          lastIntentPostMs = now;
          return true;
        };

        const anchorForEvent = (event) => {
          try {
            const path = typeof event.composedPath === "function" ? event.composedPath() : [];
            for (const node of path) {
              if (!node || node.nodeType !== 1) continue;
              const tag = String(node.tagName || "").toUpperCase();
              if ((tag === "A" || tag === "AREA") && node.href) return node;
            }
            const target = event.target;
            return target?.closest?.("a[href],area[href]") ?? null;
          } catch (_) {
            return null;
          }
        };

        document.addEventListener("click", (event) => {
          try {
            if (!event || !event.isTrusted) return;
            const anchor = anchorForEvent(event);
            if (!anchor) return;
            const href = String(anchor.href || anchor.getAttribute("href") || "");
            const scheme = href.split(":", 1)[0].toLowerCase();
            if ((scheme === "http" || scheme === "https") && reserveIntentPost()) {
              postMessage({ kind: "subframeDownloadIntent", token: bridgeToken, url: href });
            }
          } catch (_) {}
        }, true);

        return true;
      } catch (_) {
        return false;
      }
    })();
    """
    }
}

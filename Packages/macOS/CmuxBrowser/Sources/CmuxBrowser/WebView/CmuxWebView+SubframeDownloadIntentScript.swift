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
        const trustedActivationWindowMs = 2000;
        let lastIntentPostMs = 0;
        let lastTrustedActivationMs = 0;
        let observerDisconnectTimer = 0;
        let observer = null;

        const reserveIntentPost = () => {
          const now = Date.now();
          if (now - lastIntentPostMs < 500) return false;
          lastIntentPostMs = now;
          return true;
        };

        const hasRecentTrustedActivation = () => {
          try {
            return Date.now() - lastTrustedActivationMs <= trustedActivationWindowMs;
          } catch (_) {
            return false;
          }
        };

        const postHTTPIntent = (href) => {
          try {
            const value = String(href || "");
            const scheme = value.split(":", 1)[0].toLowerCase();
            if ((scheme === "http" || scheme === "https") && reserveIntentPost()) {
              postMessage({ kind: "subframeDownloadIntent", token: bridgeToken, url: value });
              return true;
            }
          } catch (_) {}
          return false;
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

        const postAnchorDownloadIntent = (anchor) => {
          try {
            if (!anchor || !anchor.hasAttribute("download")) return false;
            return postHTTPIntent(anchor.href || anchor.getAttribute("href") || "");
          } catch (_) {}
          return false;
        };

        const disconnectObserver = () => {
          try {
            if (observerDisconnectTimer) {
              clearTimeout(observerDisconnectTimer);
              observerDisconnectTimer = 0;
            }
            observer?.disconnect();
          } catch (_) {}
        };

        const scheduleObserverDisconnect = () => {
          try {
            if (observerDisconnectTimer) clearTimeout(observerDisconnectTimer);
            const remaining = trustedActivationWindowMs - (Date.now() - lastTrustedActivationMs);
            if (remaining <= 0) {
              disconnectObserver();
              return;
            }
            observerDisconnectTimer = setTimeout(disconnectObserver, remaining + 50);
          } catch (_) {}
        };

        const inspectAddedNode = (node) => {
          try {
            if (!hasRecentTrustedActivation() || !node || node.nodeType !== 1) return;
            const candidates = [];
            const tag = String(node.tagName || "").toUpperCase();
            if ((tag === "A" || tag === "AREA") && node.href) candidates.push(node);
            const nested = node.querySelectorAll?.("a[href][download],area[href][download]") ?? [];
            for (const anchor of nested) candidates.push(anchor);
            for (const anchor of candidates) {
              if (postAnchorDownloadIntent(anchor)) {
                disconnectObserver();
                return;
              }
            }
          } catch (_) {}
        };

        const armSubframeDownloadObserver = () => {
          try {
            if (!hasRecentTrustedActivation() || typeof MutationObserver !== "function") return;
            if (!observer) {
              observer = new MutationObserver((mutations) => {
                try {
                  if (!hasRecentTrustedActivation()) {
                    disconnectObserver();
                    return;
                  }
                  for (const mutation of mutations) {
                    for (const node of mutation.addedNodes || []) inspectAddedNode(node);
                  }
                } catch (_) {}
              });
            }
            const root = document.documentElement || document;
            if (!root) return;
            observer.observe(root, { childList: true, subtree: true });
            scheduleObserverDisconnect();
          } catch (_) {}
        };

        const noteTrustedActivation = (event) => {
          try {
            if (!event || !event.isTrusted) return;
            lastTrustedActivationMs = Date.now();
            armSubframeDownloadObserver();
          } catch (_) {}
        };

        document.addEventListener("click", (event) => {
          try {
            if (!event || !event.isTrusted) return;
            noteTrustedActivation(event);
            const anchor = anchorForEvent(event);
            if (!anchor) return;
            postHTTPIntent(anchor.href || anchor.getAttribute("href") || "");
          } catch (_) {}
        }, true);

        ["pointerdown", "mousedown", "keydown"].forEach((eventName) => {
          document.addEventListener(eventName, noteTrustedActivation, true);
        });

        const anchorPrototype = window.HTMLAnchorElement?.prototype ?? null;
        const originalAnchorClick = anchorPrototype?.click ?? null;
        if (typeof originalAnchorClick === "function") {
          anchorPrototype.click = function() {
            if (hasRecentTrustedActivation()) postAnchorDownloadIntent(this);
            return originalAnchorClick.apply(this, arguments);
          };
        }

        return true;
      } catch (_) {
        return false;
      }
    })();
    """
    }
}

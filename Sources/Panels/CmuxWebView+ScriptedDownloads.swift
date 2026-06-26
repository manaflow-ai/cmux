import Foundation
import ObjectiveC
import WebKit

extension CmuxWebView {
    private static let scriptedDownloadMessageHandlerName = "cmuxScriptedDownload"
    private static var scriptedDownloadHandlerInstalledKey: UInt8 = 0
    private static var scriptedDownloadTokenKey: UInt8 = 0
    private static var subframeDownloadIntentHandlerKey: UInt8 = 0
    private static let maxScriptedDownloadPayloadBytes = 100 * 1024 * 1024
    private static let maxScriptedDownloadDataURLCharacters = 140 * 1024 * 1024

    var onSubframeDownloadIntent: ((URL) -> Void)? {
        get { objc_getAssociatedObject(self, &Self.subframeDownloadIntentHandlerKey) as? ((URL) -> Void) }
        set { objc_setAssociatedObject(self, &Self.subframeDownloadIntentHandlerKey, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC) }
    }

    func clearBrowserDownloadCallbacks() {
        onContextMenuDownloadStateChanged = nil
        onSessionDownloadEvent = nil
        onSubframeDownloadIntent = nil
    }

    private static func scriptedDownloadInterceptionBootstrapScriptSource(token: String) -> String {
        """
    (() => {
      try {
        if (window.__cmuxScriptedDownloadInstalled) return true;
        window.__cmuxScriptedDownloadInstalled = true;
        const bridgeToken = "\(token)";
        const maxPayloadBytes = \(maxScriptedDownloadPayloadBytes);
        const maxDataURLCharacters = \(maxScriptedDownloadDataURLCharacters);
        const trustedActivationWindowMs = 2000;
        let isMainFrame = false;
        let blobDownloadInFlight = false;
        let lastTrustedActivationMs = 0;
        let lastDownloadPostMs = 0;
        let armSubframeDownloadObserver = () => {};
        const handledAnchors = typeof WeakSet === "function" ? new WeakSet() : null;

        try {
          isMainFrame = window.top === window;
        } catch (_) {
          isMainFrame = false;
        }

        const handler = (() => {
          try {
            return window.webkit?.messageHandlers?.\(scriptedDownloadMessageHandlerName) ?? null;
          } catch (_) {
            return null;
          }
        })();
        if (!handler) return false;
        const postMessage = handler.postMessage.bind(handler);

        const objectURLs = new Map();
        const URLCtor = window.URL || null;
        const originalCreateObjectURL = URLCtor && URLCtor.createObjectURL;
        const originalRevokeObjectURL = URLCtor && URLCtor.revokeObjectURL;

        const noteTrustedActivation = (event) => {
          try {
            if (event && event.isTrusted) {
              lastTrustedActivationMs = Date.now();
              armSubframeDownloadObserver();
            }
          } catch (_) {}
        };

        const hasRecentTrustedActivation = () => {
          try {
            return Date.now() - lastTrustedActivationMs <= trustedActivationWindowMs;
          } catch (_) {
            return false;
          }
        };

        const hasUserActivation = (event) => {
          try {
            if (event && event.isTrusted) return true;
            if (navigator.userActivation && navigator.userActivation.isActive) return true;
            return hasRecentTrustedActivation();
          } catch (_) {
            return false;
          }
        };

        const reserveDownloadPost = () => {
          const now = Date.now();
          if (now - lastDownloadPostMs < 500) return false;
          lastDownloadPostMs = now;
          return true;
        };

        const postURLDownload = (url, suggestedFilename) => {
          try {
            postMessage({
              kind: "url",
              token: bridgeToken,
              url: String(url || ""),
              suggestedFilename: String(suggestedFilename || "")
            });
          } catch (_) {}
        };

        const postDataURLDownload = (dataURL, suggestedFilename) => {
          try {
            if (String(dataURL || "").length > maxDataURLCharacters) return;
            postMessage({
              kind: "dataURL",
              token: bridgeToken,
              dataURL: String(dataURL || ""),
              suggestedFilename: String(suggestedFilename || "")
            });
          } catch (_) {}
        };
        const readBlobForDownload = (blob, suggestedFilename, fallbackURL) => {
          try {
            if (!blob) return false;
            if (blobDownloadInFlight) return false;
            if (typeof blob.size === "number" && blob.size > maxPayloadBytes) {
              postURLDownload(fallbackURL, suggestedFilename);
              return true;
            }
            blobDownloadInFlight = true;
            const filename = String(suggestedFilename || blob.name || "");
            const reader = new FileReader();
            const finish = () => {
              blobDownloadInFlight = false;
            };
            reader.onload = () => {
              if (typeof reader.result === "string" && reader.result.length > 0) {
                if (reader.result.length > maxDataURLCharacters) {
                  postURLDownload(fallbackURL, filename);
                } else {
                  postDataURLDownload(reader.result, filename);
                }
              }
              finish();
            };
            reader.onerror = () => {
              postURLDownload(fallbackURL, filename);
              finish();
            };
            reader.onabort = () => {
              postURLDownload(fallbackURL, filename);
              finish();
            };
            reader.readAsDataURL(blob);
            return true;
          } catch (_) {
            blobDownloadInFlight = false;
          }
          return false;
        };

        const postBlobURLDownload = (url, suggestedFilename) => {
          try {
            const storedBlob = objectURLs.get(String(url));
            if (storedBlob) {
              return readBlobForDownload(storedBlob, suggestedFilename, url);
            }
            fetch(url)
              .then((response) => response.blob())
              .then((blob) => readBlobForDownload(blob, suggestedFilename, url))
              .catch(() => postURLDownload(url, suggestedFilename));
            return true;
          } catch (_) {}
          return false;
        };

        if (typeof originalCreateObjectURL === "function") {
          URLCtor.createObjectURL = function(object) {
            const url = originalCreateObjectURL.apply(this, arguments);
            try {
              if (object instanceof Blob) {
                objectURLs.set(String(url), object);
              }
            } catch (_) {}
            return url;
          };
        }

        if (typeof originalRevokeObjectURL === "function") {
          URLCtor.revokeObjectURL = function(url) {
            try {
              objectURLs.delete(String(url));
            } catch (_) {}
            return originalRevokeObjectURL.apply(this, arguments);
          };
        }

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

        const suggestedFilenameForAnchor = (anchor) => {
          try {
            const attr = anchor.getAttribute("download");
            if (typeof attr === "string" && attr.trim().length > 0) return attr;
            if (typeof anchor.download === "string" && anchor.download.trim().length > 0) {
              return anchor.download;
            }
          } catch (_) {}
          return "";
        };

        const interceptAnchorDownload = (anchor, event) => {
          try {
            if (!hasUserActivation(event)) return false;
            if (!anchor || !anchor.hasAttribute("download")) return false;
            const href = String(anchor.href || anchor.getAttribute("href") || "");
            if (!href) return false;
            const scheme = href.split(":", 1)[0].toLowerCase();
            const suggestedFilename = suggestedFilenameForAnchor(anchor);

            if (!isMainFrame && (scheme === "blob" || scheme === "data")) return false;
            if (scheme === "blob") {
              if (!reserveDownloadPost()) return false;
              return postBlobURLDownload(href, suggestedFilename);
            }
            if (scheme === "data") {
              if (href.length > maxDataURLCharacters) return false;
              if (!reserveDownloadPost()) return false;
              postURLDownload(href, suggestedFilename);
              return true;
            }
          } catch (_) {}
          return false;
        };

        document.addEventListener("click", (event) => {
          const anchor = anchorForEvent(event);
          if (anchor && handledAnchors?.has(anchor)) {
            event.preventDefault();
            event.stopPropagation();
            return;
          }
          if (!interceptAnchorDownload(anchor, event)) return;
          event.preventDefault();
          event.stopPropagation();
        }, true);

        if (!isMainFrame && typeof MutationObserver === "function") {
          let observerDisconnectTimer = 0;
          let observer = null;
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
              if (!hasRecentTrustedActivation()) return;
              if (!node || node.nodeType !== 1) return;
              const candidates = [];
              const tag = String(node.tagName || "").toUpperCase();
              if ((tag === "A" || tag === "AREA") && node.href) candidates.push(node);
              const nested = node.querySelectorAll?.("a[href][download],area[href][download]") ?? [];
              for (const anchor of nested) candidates.push(anchor);
              for (const anchor of candidates) {
                if (interceptAnchorDownload(anchor, null)) {
                  handledAnchors?.add(anchor);
                  disconnectObserver();
                  return;
                }
              }
            } catch (_) {}
          };
          observer = new MutationObserver((mutations) => {
            try {
              if (!hasRecentTrustedActivation()) {
                disconnectObserver();
                return;
              }
              for (const mutation of mutations) {
                for (const node of mutation.addedNodes || []) {
                  inspectAddedNode(node);
                }
              }
            } catch (_) {}
          });
          armSubframeDownloadObserver = () => {
            try {
              if (!hasRecentTrustedActivation()) return;
              const root = document.documentElement || document;
              if (!root) return;
              observer.observe(root, { childList: true, subtree: true });
              scheduleObserverDisconnect();
            } catch (_) {}
          };
        }

        ["pointerdown", "mousedown", "keydown", "click"].forEach((eventName) => {
          document.addEventListener(eventName, noteTrustedActivation, true);
        });

        const anchorPrototype = window.HTMLAnchorElement?.prototype ?? null;
        const originalAnchorClick = anchorPrototype?.click ?? null;
        if (isMainFrame && typeof originalAnchorClick === "function") {
          anchorPrototype.click = function() {
            if (interceptAnchorDownload(this, null)) return;
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

    func installScriptedDownloadInterception() {
        let userContentController = configuration.userContentController
        if objc_getAssociatedObject(
            userContentController,
            &Self.scriptedDownloadHandlerInstalledKey
        ) != nil {
            return
        }

        let token = UUID().uuidString
        objc_setAssociatedObject(userContentController, &Self.scriptedDownloadTokenKey, token, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        userContentController.addUserScript(
            WKUserScript(
                source: Self.scriptedDownloadInterceptionBootstrapScriptSource(token: token),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        userContentController.addUserScript(
            Self.subframeDownloadIntentScript(token: token, handlerName: Self.scriptedDownloadMessageHandlerName)
        )
        userContentController.add(
            Self.sharedScriptedDownloadMessageHandler,
            name: Self.scriptedDownloadMessageHandlerName
        )
        objc_setAssociatedObject(
            userContentController,
            &Self.scriptedDownloadHandlerInstalledKey,
            NSNumber(value: true),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    fileprivate func handleScriptedDownloadMessage(_ body: [String: Any], isMainFrame: Bool) {
        let expectedToken = objc_getAssociatedObject(
            configuration.userContentController,
            &Self.scriptedDownloadTokenKey
        ) as? String
        guard let token = body["token"] as? String,
              let expectedToken,
              token == expectedToken else {
#if DEBUG
            debugContextDownload("browser.scriptdl.message stage=rejectToken")
#endif
            return
        }
        guard let kind = body["kind"] as? String, isMainFrame || kind == "subframeDownloadIntent" else { return }
        let suggestedFilename = body["suggestedFilename"] as? String
        let urlString: String?
        switch kind {
        case "subframeDownloadIntent":
            guard let rawURL = body["url"] as? String,
                  let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            onSubframeDownloadIntent?(url)
            return
        case "url":
            urlString = body["url"] as? String
        case "dataURL":
            urlString = body["dataURL"] as? String
            if let dataURL = urlString, dataURL.count > Self.maxScriptedDownloadDataURLCharacters {
#if DEBUG
                debugContextDownload("browser.scriptdl.message stage=rejectOversizeDataURL chars=\(dataURL.count)")
#endif
                return
            }
        default:
            urlString = nil
        }

        guard let rawURL = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty,
              let url = URL(string: rawURL) else {
#if DEBUG
            debugContextDownload("browser.scriptdl.message stage=rejectInvalid kind=\(kind)")
#endif
            return
        }

        if url.scheme?.caseInsensitiveCompare("data") == .orderedSame,
           rawURL.count > Self.maxScriptedDownloadDataURLCharacters {
#if DEBUG
            debugContextDownload("browser.scriptdl.message stage=rejectOversizeDataURL chars=\(rawURL.count)")
#endif
            return
        }

        startScriptedDownload(url, suggestedFilename: suggestedFilename)
    }

    private func startScriptedDownload(
        _ url: URL,
        suggestedFilename: String?
    ) {
        guard Self.isScriptedDownloadSupportedURL(url) else {
#if DEBUG
            debugContextDownload("browser.scriptdl.start stage=rejectUnsupportedScheme scheme=\(url.scheme ?? "nil")")
#endif
            return
        }
        let traceID = Self.makeContextDownloadTraceID(prefix: "scriptdl")
        debugContextDownload("browser.scriptdl.start trace=\(traceID) scheme=\(url.scheme ?? "nil")")
        if url.scheme?.caseInsensitiveCompare("blob") == .orderedSame {
            startScriptedWebKitDownload(url, suggestedFilename: suggestedFilename, traceID: traceID)
            return
        }
        downloadURLViaSession(
            url,
            suggestedFilename: suggestedFilename,
            sender: nil,
            fallbackAction: nil,
            fallbackTarget: nil,
            traceID: traceID
        )
    }

    private static func isScriptedDownloadSupportedURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "data" || scheme == "blob"
    }

    private func startScriptedWebKitDownload(
        _ url: URL,
        suggestedFilename: String?,
        traceID: String
    ) {
        guard let downloadDelegate = cmuxDownloadDelegate else {
#if DEBUG
            debugContextDownload("browser.scriptdl.webkit trace=\(traceID) stage=rejectMissingDelegate")
#endif
            return
        }
        if #available(macOS 11.3, *) {
            startDownload(using: URLRequest(url: url)) { download in
#if DEBUG
                self.debugContextDownload("browser.scriptdl.webkit trace=\(traceID) stage=didStart")
#endif
                if let browserDownloadDelegate = downloadDelegate as? BrowserDownloadDelegate {
                    browserDownloadDelegate.setSuggestedFilenameOverride(suggestedFilename, for: download)
                }
                download.delegate = downloadDelegate
            }
        } else {
#if DEBUG
            debugContextDownload("browser.scriptdl.webkit trace=\(traceID) stage=rejectUnavailable")
#endif
        }
    }

    static func cookiesForDownloadRequest(_ cookies: [HTTPCookie], url: URL) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let isHTTPS = url.scheme?.caseInsensitiveCompare("https") == .orderedSame
        let now = Date.now

        return cookies.filter { cookie in
            if cookie.isSecure && !isHTTPS { return false }
            if let expires = cookie.expiresDate, expires <= now { return false }
            guard domain(cookie.domain, matches: host) else { return false }
            return path(cookie.path, matches: requestPath)
        }
    }

    private static func domain(_ cookieDomain: String, matches host: String) -> Bool {
        let normalized = cookieDomain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard !normalized.isEmpty else { return false }
        if cookieDomain.hasPrefix(".") {
            return host == normalized || host.hasSuffix(".\(normalized)")
        }
        return host == normalized
    }

    private static func path(_ cookiePath: String, matches requestPath: String) -> Bool {
        let normalized = cookiePath.isEmpty ? "/" : cookiePath
        if normalized == "/" || requestPath == normalized { return true }
        guard requestPath.hasPrefix(normalized) else { return false }
        return normalized.hasSuffix("/") || requestPath.dropFirst(normalized.count).first == "/"
    }

    private static let sharedScriptedDownloadMessageHandler = ScriptedDownloadMessageHandler()
}

private final class ScriptedDownloadMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let webView = message.webView as? CmuxWebView,
              let body = message.body as? [String: Any] else {
            return
        }
        MainActor.assumeIsolated {
            webView.handleScriptedDownloadMessage(body, isMainFrame: message.frameInfo.isMainFrame)
        }
    }
}

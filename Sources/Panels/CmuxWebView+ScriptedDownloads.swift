import Foundation
import ObjectiveC
import WebKit

extension CmuxWebView {
    private static let scriptedDownloadMessageHandlerName = "cmuxScriptedDownload"
    private static var scriptedDownloadHandlerInstalledKey: UInt8 = 0
    private static let scriptedDownloadInterceptionBootstrapScriptSource = """
    (() => {
      try {
        if (window.__cmuxScriptedDownloadInstalled) return true;
        window.__cmuxScriptedDownloadInstalled = true;

        const handler = (() => {
          try {
            return window.webkit?.messageHandlers?.\(scriptedDownloadMessageHandlerName) ?? null;
          } catch (_) {
            return null;
          }
        })();
        if (!handler) return false;

        const objectURLs = new Map();
        const URLCtor = window.URL || null;
        const originalCreateObjectURL = URLCtor && URLCtor.createObjectURL;
        const originalRevokeObjectURL = URLCtor && URLCtor.revokeObjectURL;

        const postURLDownload = (url, suggestedFilename) => {
          try {
            handler.postMessage({
              kind: "url",
              url: String(url || ""),
              suggestedFilename: String(suggestedFilename || "")
            });
          } catch (_) {}
        };

        const postDataURLDownload = (dataURL, suggestedFilename) => {
          try {
            handler.postMessage({
              kind: "dataURL",
              dataURL: String(dataURL || ""),
              suggestedFilename: String(suggestedFilename || "")
            });
          } catch (_) {}
        };

        const readBlobForDownload = (blob, suggestedFilename) => {
          try {
            if (!blob) return;
            const filename = String(suggestedFilename || blob.name || "");
            const reader = new FileReader();
            reader.onload = () => {
              if (typeof reader.result === "string" && reader.result.length > 0) {
                postDataURLDownload(reader.result, filename);
              }
            };
            reader.readAsDataURL(blob);
          } catch (_) {}
        };

        const postBlobURLDownload = (url, suggestedFilename) => {
          try {
            const storedBlob = objectURLs.get(String(url));
            if (storedBlob) {
              readBlobForDownload(storedBlob, suggestedFilename);
              return;
            }
            fetch(url)
              .then((response) => response.blob())
              .then((blob) => readBlobForDownload(blob, suggestedFilename))
              .catch(() => {});
          } catch (_) {}
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

        const interceptAnchorDownload = (anchor) => {
          try {
            if (!anchor || !anchor.hasAttribute("download")) return false;
            const href = String(anchor.href || anchor.getAttribute("href") || "");
            if (!href) return false;
            const scheme = href.split(":", 1)[0].toLowerCase();
            const suggestedFilename = suggestedFilenameForAnchor(anchor);

            if (scheme === "blob") {
              postBlobURLDownload(href, suggestedFilename);
              return true;
            }
            if (scheme === "data" || scheme === "http" || scheme === "https" || scheme === "file") {
              postURLDownload(href, suggestedFilename);
              return true;
            }
          } catch (_) {}
          return false;
        };

        document.addEventListener("click", (event) => {
          const anchor = anchorForEvent(event);
          if (!interceptAnchorDownload(anchor)) return;
          event.preventDefault();
          event.stopPropagation();
        }, true);

        const anchorPrototype = window.HTMLAnchorElement?.prototype ?? null;
        const originalAnchorClick = anchorPrototype?.click ?? null;
        if (typeof originalAnchorClick === "function") {
          anchorPrototype.click = function() {
            if (interceptAnchorDownload(this)) return;
            return originalAnchorClick.apply(this, arguments);
          };
        }

        return true;
      } catch (_) {
        return false;
      }
    })();
    """

    func installScriptedDownloadInterception() {
        let userContentController = configuration.userContentController
        if objc_getAssociatedObject(
            userContentController,
            &Self.scriptedDownloadHandlerInstalledKey
        ) != nil {
            return
        }

        userContentController.addUserScript(
            WKUserScript(
                source: Self.scriptedDownloadInterceptionBootstrapScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
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

    fileprivate func handleScriptedDownloadMessage(_ body: [String: Any]) {
        guard let kind = body["kind"] as? String else { return }
        let suggestedFilename = body["suggestedFilename"] as? String
        let urlString: String?
        switch kind {
        case "url":
            urlString = body["url"] as? String
        case "dataURL":
            urlString = body["dataURL"] as? String
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

        startScriptedDownload(url, suggestedFilename: suggestedFilename)
    }

    private func startScriptedDownload(
        _ url: URL,
        suggestedFilename: String?
    ) {
        let traceID = Self.makeContextDownloadTraceID(prefix: "scriptdl")
        debugContextDownload("browser.scriptdl.start trace=\(traceID) scheme=\(url.scheme ?? "nil")")
        downloadURLViaSession(
            url,
            suggestedFilename: suggestedFilename,
            sender: nil,
            fallbackAction: nil,
            fallbackTarget: nil,
            traceID: traceID
        )
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
            webView.handleScriptedDownloadMessage(body)
        }
    }
}

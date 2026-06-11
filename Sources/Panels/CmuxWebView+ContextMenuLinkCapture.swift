import AppKit
import ObjectiveC
import WebKit

/// Context-menu link resolution for `CmuxWebView`.
///
/// WebKit's own context-menu hit test knows the exact element under the
/// cursor but does not expose it through public macOS API, so the custom menu
/// actions ("Open Link in Default Browser", "Open Link in New Tab") used to
/// re-resolve the link later with a main-frame `document.elementFromPoint`
/// hit test at the AppKit event coordinates. That re-resolution can disagree
/// with the link the user actually right-clicked (page zoom scales CSS
/// coordinates relative to view points, and links inside iframes are
/// invisible to a main-frame hit test), which opened the wrong link.
///
/// The capture hook below records the contextmenu event target's closest
/// anchor at right-click time, which is immune to coordinate skew and works
/// in every frame. The coordinate-based hit tests remain as fallbacks.
extension CmuxWebView {
    private static let contextMenuLinkCaptureMessageHandlerName = "cmuxContextMenuLinkCapture"
    private static var contextMenuLinkCaptureInstalledKey: UInt8 = 0

    /// Test seam: synthetic (`isTrusted == false`) contextmenu events are
    /// ignored so page JavaScript cannot plant a decoy link, but unit tests
    /// have no way to produce a trusted DOM event, so they opt back in.
    static var contextMenuLinkCaptureAcceptsUntrustedEventsForTesting = false

    /// Isolated content world for the context-menu link capture hook. Both the
    /// injected script and the message handler live here, not the page world,
    /// so page JavaScript cannot post fake link reports and CAPTCHA providers
    /// in cross-origin iframes cannot fingerprint the hook.
    private static let contextMenuLinkCaptureContentWorld =
        WKContentWorld.world(name: contextMenuLinkCaptureMessageHandlerName)

    /// Document-start hook, injected into every frame, that reports the link
    /// under the cursor the moment a `contextmenu` event fires. Purely passive
    /// capture-phase listener, same fingerprinting-safety reasoning as the
    /// media-playback hook in `BrowserPanel+MediaPlayback.swift`.
    private static let contextMenuLinkCaptureBootstrapScriptSource = """
    (() => {
      try {
        const post = (href) => {
          try {
            window.webkit.messageHandlers["\(contextMenuLinkCaptureMessageHandlerName)"].postMessage({
              href: typeof href === "string" ? href : ""
            });
          } catch (_) {}
        };
        const linkForEvent = (event) => {
          try {
            const path = typeof event.composedPath === "function" ? event.composedPath() : [];
            for (const node of path) {
              if (!node || node.nodeType !== 1) continue;
              const tag = node.tagName;
              if ((tag === "A" || tag === "AREA") && node.href) return String(node.href);
            }
            const target = event.target;
            if (target && target.closest) {
              const link = target.closest("a[href],area[href]");
              if (link && link.href) return String(link.href);
            }
          } catch (_) {}
          return "";
        };
        window.addEventListener("contextmenu", (event) => {
          post(linkForEvent(event));
        }, true);
      } catch (_) {}
    })();
    """

    private static let sharedContextMenuLinkCaptureMessageHandler = ContextMenuLinkCaptureMessageHandler()

    /// How far apart the DOM contextmenu capture and the AppKit menu open may
    /// be while still describing the same right-click.
    private static let contextMenuLinkCaptureMaxAge: TimeInterval = 2.0

    func installContextMenuLinkCapture() {
        let userContentController = configuration.userContentController
        if objc_getAssociatedObject(
            userContentController,
            &Self.contextMenuLinkCaptureInstalledKey
        ) != nil {
            return
        }

        userContentController.addUserScript(
            WKUserScript(
                source: Self.contextMenuLinkCaptureBootstrapScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: Self.contextMenuLinkCaptureContentWorld
            )
        )
        userContentController.add(
            Self.sharedContextMenuLinkCaptureMessageHandler,
            contentWorld: Self.contextMenuLinkCaptureContentWorld,
            name: Self.contextMenuLinkCaptureMessageHandlerName
        )
        objc_setAssociatedObject(
            userContentController,
            &Self.contextMenuLinkCaptureInstalledKey,
            NSNumber(value: true),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    func noteContextMenuCapturedLink(_ url: URL?) {
        contextMenuCapturedLink = ContextMenuCapturedLink(
            url: url,
            uptime: ProcessInfo.processInfo.systemUptime
        )
    }

    private func capturedContextMenuLinkURLForCurrentMenu() -> URL? {
        guard let captured = contextMenuCapturedLink,
              let menuOpenUptime = lastContextMenuOpenUptime,
              abs(captured.uptime - menuOpenUptime) <= Self.contextMenuLinkCaptureMaxAge
        else { return nil }
        return captured.url
    }

    func resolveContextMenuLinkURL(at point: NSPoint, completion: @escaping (URL?) -> Void) {
        if let contextMenuLinkURLProvider {
            contextMenuLinkURLProvider(self, point, completion)
            return
        }
        // Prefer the link captured at contextmenu time: it is the actual event
        // target, so it stays correct under page zoom and inside iframes where
        // a main-frame elementFromPoint hit test resolves the wrong element.
        if let captured = capturedContextMenuLinkURLForCurrentMenu() {
            completion(captured)
            return
        }
        findLinkURLAtPoint(point, completion: completion)
    }

    func canOpenInDefaultBrowser(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "http" || scheme == "https"
    }

    func openContextMenuLinkInDefaultBrowser(_ url: URL) {
        if let contextMenuDefaultBrowserOpener {
            _ = contextMenuDefaultBrowserOpener(url)
            return
        }
        _ = NSWorkspace.shared.open(url)
    }

    /// Converts a view-local AppKit point (bottom-left origin) to the CSS
    /// viewport coordinates `document.elementFromPoint` expects. `pageZoom`
    /// scales CSS pixels relative to view points, so on a zoomed page the
    /// division is required or the hit test lands on the wrong element.
    func cssViewportPoint(for point: NSPoint) -> CGPoint {
        let zoom = pageZoom > 0 ? pageZoom : 1
        return CGPoint(x: point.x / zoom, y: (bounds.height - point.y) / zoom)
    }

    /// Finds the nearest anchor element at a given view-local point.
    /// Used as a context-menu download fallback.
    func findLinkAtPoint(_ point: NSPoint, completion: @escaping (URL?) -> Void) {
        let cssPoint = cssViewportPoint(for: point)
        let js = """
        (() => {
            let el = document.elementFromPoint(\(cssPoint.x), \(cssPoint.y));
            while (el) {
                if (el.tagName === 'A' && el.href) return el.href;
                el = el.parentElement;
            }
            return '';
        })();
        """
        evaluateJavaScript(js) { result, _ in
            guard let href = result as? String, !href.isEmpty,
                  let url = URL(string: href) else {
                completion(nil)
                return
            }
            completion(url)
        }
    }

    /// Resolve the topmost link URL near a point, accounting for overlay layers.
    func findLinkURLAtPoint(_ point: NSPoint, completion: @escaping (URL?) -> Void) {
        let cssPoint = cssViewportPoint(for: point)
        let js = """
        (() => {
            const x = \(cssPoint.x);
            const y = \(cssPoint.y);
            const normalize = (raw) => {
                if (!raw || typeof raw !== 'string') return '';
                const trimmed = raw.trim();
                if (!trimmed) return '';
                if (trimmed.startsWith('//')) return window.location.protocol + trimmed;
                return trimmed;
            };
            const collectChain = (start) => {
                const out = [];
                const seen = new Set();
                while (start && !seen.has(start)) {
                    seen.add(start);
                    out.push(start);
                    start = start.parentElement;
                }
                return out;
            };
            const linkFromElement = (el) => {
                if (!el) return '';
                const attr = (name) => normalize(el.getAttribute ? el.getAttribute(name) : '');
                if (el.closest) {
                    const closestLink = el.closest('a[href],area[href]');
                    if (closestLink && closestLink.href) return normalize(closestLink.href);
                }
                if ((el.tagName === 'A' || el.tagName === 'AREA') && el.href) {
                    return normalize(el.href);
                }
                const attrCandidates = ['href', 'data-href', 'data-url', 'data-link', 'data-link-url'];
                for (const name of attrCandidates) {
                    const v = attr(name);
                    if (v) return v;
                }
                if (el.querySelector) {
                    const nestedLink = el.querySelector('a[href],area[href]');
                    if (nestedLink && nestedLink.href) return normalize(nestedLink.href);
                }
                return '';
            };
            const tryNodes = (nodes) => {
                for (const start of nodes) {
                    for (const node of collectChain(start)) {
                        const found = linkFromElement(node);
                        if (found) return found;
                    }
                    if (start && start.shadowRoot && start.shadowRoot.elementFromPoint) {
                        const inner = start.shadowRoot.elementFromPoint(x, y);
                        if (inner) {
                            for (const node of collectChain(inner)) {
                                const found = linkFromElement(node);
                                if (found) return found;
                            }
                        }
                    }
                }
                return '';
            };
            const nodes = document.elementsFromPoint ? document.elementsFromPoint(x, y) : [];
            const found = tryNodes(nodes);
            if (found) return found;
            const single = document.elementFromPoint ? document.elementFromPoint(x, y) : null;
            return linkFromElement(single) || '';
        })();
        """
        evaluateJavaScript(js) { result, _ in
            guard let href = result as? String, !href.isEmpty,
                  let url = URL(string: href) else {
                completion(nil)
                return
            }
            completion(url)
        }
    }
}

private final class ContextMenuLinkCaptureMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let webView = message.webView as? CmuxWebView else { return }
        let href = (message.body as? [String: Any])?["href"] as? String ?? ""
        let url = href.isEmpty ? nil : URL(string: href)
        Task { @MainActor [weak webView] in
            webView?.noteContextMenuCapturedLink(url)
        }
    }
}

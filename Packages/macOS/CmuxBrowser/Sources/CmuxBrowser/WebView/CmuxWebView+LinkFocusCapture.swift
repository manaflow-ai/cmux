public import ObjectiveC
public import WebKit

/// Keyboard-focused link reporting for `CmuxWebView`.
///
/// WebKit's `_webView:mouseDidMoveOverElement:` reports the link under the
/// pointer but says nothing when a link takes keyboard focus (Option-Tab), so
/// the pane's link hover indicator has no native source for it. The hook
/// below reports the focused link from the page instead.
extension CmuxWebView {
    private static let linkFocusCaptureMessageHandlerName = "cmuxLinkFocusCapture"
    private static var linkFocusCaptureInstalledKey: UInt8 = 0

    /// Isolated content world for the link focus hook, for the same reasons
    /// as the context-menu link capture: page JavaScript cannot post fake
    /// reports, and CAPTCHA providers cannot fingerprint the hook.
    private static let linkFocusCaptureContentWorld =
        WKContentWorld.world(name: linkFocusCaptureMessageHandlerName)

    /// Document-start hook, injected into every frame, that reports a link
    /// when it takes keyboard focus and an empty string when it loses focus.
    /// `:focus-visible` limits it to keyboard focus, so clicking a link or a
    /// page calling `focus()` after a click reports nothing. Purely passive
    /// capture-phase listeners.
    private static let linkFocusCaptureBootstrapScriptSource = """
    (() => {
      try {
        const post = (href) => {
          try {
            window.webkit.messageHandlers["\(linkFocusCaptureMessageHandlerName)"].postMessage({
              href: typeof href === "string" ? href : ""
            });
          } catch (_) {}
        };
        const linkForTarget = (target) => {
          try {
            if (!target || target.nodeType !== 1) return null;
            const tag = target.tagName;
            if ((tag === "A" || tag === "AREA") && target.href) return target;
          } catch (_) {}
          return null;
        };
        const targetForEvent = (event) => {
          const path = typeof event.composedPath === "function" ? event.composedPath() : [];
          return path.length > 0 ? path[0] : event.target;
        };
        window.addEventListener("focusin", (event) => {
          const link = linkForTarget(targetForEvent(event));
          if (!link) return;
          let keyboardFocus = true;
          try { keyboardFocus = link.matches(":focus-visible"); } catch (_) {}
          if (keyboardFocus) post(String(link.href));
        }, true);
        window.addEventListener("focusout", (event) => {
          if (linkForTarget(targetForEvent(event))) post("");
        }, true);
      } catch (_) {}
    })();
    """

    private static let sharedLinkFocusCaptureMessageHandler = LinkFocusCaptureMessageHandler()

    /// Adds the link focus hook and its message handler to this web view's
    /// user content controller, once per controller.
    func installLinkFocusCapture() {
        let userContentController = configuration.userContentController
        if objc_getAssociatedObject(
            userContentController,
            &Self.linkFocusCaptureInstalledKey
        ) != nil {
            return
        }

        userContentController.addUserScript(
            WKUserScript(
                source: Self.linkFocusCaptureBootstrapScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: Self.linkFocusCaptureContentWorld
            )
        )
        userContentController.add(
            Self.sharedLinkFocusCaptureMessageHandler,
            contentWorld: Self.linkFocusCaptureContentWorld,
            name: Self.linkFocusCaptureMessageHandlerName
        )
        objc_setAssociatedObject(
            userContentController,
            &Self.linkFocusCaptureInstalledKey,
            NSNumber(value: true),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}

private final class LinkFocusCaptureMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let webView = message.webView as? CmuxWebView else { return }
        let body = message.body as? [String: Any]
        let href = body?["href"] as? String ?? ""
        let url = href.isEmpty ? nil : URL(string: href)
        // WebKit delivers script messages on the main thread; apply the report
        // synchronously so a focus and the blur that follows stay in order.
        MainActor.assumeIsolated {
            webView.onKeyboardFocusedLinkChanged?(url)
        }
    }
}

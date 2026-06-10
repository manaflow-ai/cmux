import AppKit
import Bonsplit
import ObjectiveC
import UniformTypeIdentifiers
import WebKit


// MARK: - Paste-as-plain-text focus tracking (injected JS + message handler)
extension CmuxWebView {
    private static let pasteAsPlainTextFocusMessageHandlerName = "cmuxPasteAsPlainTextFocus"
    private static var pasteAsPlainTextFocusHandlerInstalledKey: UInt8 = 0
    private static let pasteAsPlainTextSharedHelpersScriptSource = """
    const __cmuxPasteAsPlainTextHelpers = (() => {
      const existing = window.__cmuxPasteAsPlainTextHelpers;
      if (existing) return existing;

      const supportedTextInputTypes = new Set([
        "",
        "text",
        "search",
        "tel",
        "url",
        "email",
        "password",
        "number",
        "date",
        "datetime-local",
        "month",
        "time",
        "week"
      ]);

      const deepestActiveElement = (root) => {
        let active = root?.activeElement ?? null;
        while (active) {
          const shadowActive = active.shadowRoot?.activeElement ?? null;
          if (shadowActive && shadowActive !== active) {
            active = shadowActive;
            continue;
          }

          const tagName = typeof active.tagName === "string" ? active.tagName.toUpperCase() : "";
          if (tagName === "IFRAME") {
            try {
              const frameActive = active.contentDocument?.activeElement ?? null;
              if (frameActive && frameActive !== active) {
                active = frameActive;
                continue;
              }
            } catch (_) {}
          }

          break;
        }
        return active;
      };

      const isPlainTextTextControl = (el) => {
        if (!el || el.disabled || el.readOnly) return false;

        const tagName = typeof el.tagName === "string" ? el.tagName.toUpperCase() : "";
        if (tagName === "TEXTAREA") return true;
        if (tagName !== "INPUT") return false;

        const type = typeof el.type === "string" ? el.type.toLowerCase() : "text";
        return supportedTextInputTypes.has(type);
      };

      const isFocusedCrossOriginFrameElement = (el) => {
        const tagName = typeof el?.tagName === "string" ? el.tagName.toUpperCase() : "";
        if (tagName !== "IFRAME") return false;
        try {
          void el.contentDocument;
          return false;
        } catch (_) {
          return true;
        }
      };

      const resolvedCandidateElement = (el) => {
        if (!el) return deepestActiveElement(document);

        const shadowActive = el.shadowRoot?.activeElement ?? null;
        if (shadowActive && shadowActive !== el) {
          return deepestActiveElement(el.shadowRoot) ?? shadowActive;
        }

        const tagName = typeof el.tagName === "string" ? el.tagName.toUpperCase() : "";
        if (tagName === "IFRAME") {
          try {
            return deepestActiveElement(el.contentDocument) ?? el;
          } catch (_) {}
        }

        return el;
      };

      const editableTarget = (el) => {
        const candidate = resolvedCandidateElement(el);
        if (!candidate) return null;
        if (isPlainTextTextControl(candidate)) return candidate;
        if (isFocusedCrossOriginFrameElement(candidate)) return candidate;
        if (candidate.isContentEditable) return candidate;
        return candidate.closest?.('[contenteditable]:not([contenteditable="false"])') ?? null;
      };

      const helpers = {
        deepestActiveElement,
        isPlainTextTextControl,
        isFocusedCrossOriginFrameElement,
        resolvedCandidateElement,
        editableTarget,
        canPasteAsPlainTextInto(el) {
          return !!editableTarget(el);
        }
      };
      window.__cmuxPasteAsPlainTextHelpers = helpers;
      return helpers;
    })();
    """
    static let pasteAsPlainTextFocusTrackingBootstrapScriptSource = """
    (() => {
      try {
        if (window.__cmuxPasteAsPlainTextFocusTrackerInstalled) return true;
        window.__cmuxPasteAsPlainTextFocusTrackerInstalled = true;

        const handler = (() => {
          try {
            return window.webkit?.messageHandlers?.\(pasteAsPlainTextFocusMessageHandlerName) ?? null;
          } catch (_) {
            return null;
          }
        })();

        \(pasteAsPlainTextSharedHelpersScriptSource)

        const publishState = { lastCanPaste: null };

        const publish = (canPaste) => {
          if (publishState.lastCanPaste === canPaste) return;
          publishState.lastCanPaste = canPaste;
          window.__cmuxPasteAsPlainTextTargetAvailable = canPaste;
          try {
            handler?.postMessage({ canPaste });
          } catch (_) {}
        };

        window.__cmuxCanPasteAsPlainTextIntoCurrentFocus = () => {
          return __cmuxPasteAsPlainTextHelpers.canPasteAsPlainTextInto(document.activeElement);
        };

        const publishForElement = (el) => {
          publish(__cmuxPasteAsPlainTextHelpers.canPasteAsPlainTextInto(el));
        };

        document.addEventListener("focusin", (ev) => {
          publishForElement(ev && ev.target ? ev.target : document.activeElement);
        }, true);
        document.addEventListener("focusout", () => {
          requestAnimationFrame(() => publishForElement(document.activeElement));
        }, true);
        document.addEventListener("selectionchange", () => {
          publishForElement(document.activeElement);
        }, true);
        document.addEventListener("input", () => {
          publishForElement(document.activeElement);
        }, true);
        document.addEventListener("change", () => {
          publishForElement(document.activeElement);
        }, true);
        document.addEventListener("mousedown", (ev) => {
          const target = ev && ev.target ? ev.target : null;
          if (!__cmuxPasteAsPlainTextHelpers.canPasteAsPlainTextInto(target)) {
            publish(false);
          }
        }, true);
        window.addEventListener("beforeunload", () => {
          publish(false);
        }, true);

        publishForElement(document.activeElement);
        return true;
      } catch (_) {
        return false;
      }
    })();
    """

    private final class PasteAsPlainTextFocusMessageHandler: NSObject, WKScriptMessageHandler {
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let webView = message.webView as? CmuxWebView else {
                return
            }
            guard let body = message.body as? [String: Any],
                  let canPaste = body["canPaste"] as? Bool else {
                return
            }
            Task { @MainActor [weak webView] in
                webView?.updatePasteAsPlainTextTargetAvailable(canPaste)
            }
        }
    }

    private static let sharedPasteAsPlainTextFocusMessageHandler = PasteAsPlainTextFocusMessageHandler()

    func installPasteAsPlainTextFocusTracking() {
        let userContentController = configuration.userContentController
        if objc_getAssociatedObject(
            userContentController,
            &Self.pasteAsPlainTextFocusHandlerInstalledKey
        ) != nil {
            return
        }

        userContentController.add(
            Self.sharedPasteAsPlainTextFocusMessageHandler,
            name: Self.pasteAsPlainTextFocusMessageHandlerName
        )
        objc_setAssociatedObject(
            userContentController,
            &Self.pasteAsPlainTextFocusHandlerInstalledKey,
            NSNumber(value: true),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private func updatePasteAsPlainTextTargetAvailable(_ available: Bool) {
        guard pasteAsPlainTextTargetAvailable != available else { return }
        pasteAsPlainTextTargetAvailable = available
#if DEBUG
        cmuxDebugLog(
            "browser.pasteAsPlainText.target " +
            "web=\(ObjectIdentifier(self)) available=\(available ? 1 : 0)"
        )
#endif
    }

}

/// JavaScript sources and the message-handler name for cmux's browser
/// paste-as-plain-text focus tracking.
///
/// `focusTrackingBootstrapSource` is injected at document start (main frame
/// only) and installs idempotent focus/selection listeners that publish whether
/// the currently focused element can accept a plain-text paste. It posts changes
/// to the `focusMessageHandlerName` WebKit message handler and mirrors the latest
/// value onto `window.__cmuxPasteAsPlainTextTargetAvailable`. It interpolates
/// `sharedHelpersSource`, which defines the shared
/// `window.__cmuxPasteAsPlainTextHelpers` editable-target resolver (shadow DOM,
/// cross-origin iframe, and contenteditable aware) reused by both the tracker and
/// the synchronous preflight. `pageCanAcceptPlainTextPreflightSource` is a small
/// side-effect-free read of `window.__cmuxCanPasteAsPlainTextIntoCurrentFocus`
/// used as a synchronous Cmd+Shift+V preflight.
///
/// The host app keeps the `WKScriptMessageHandler` subclass, the
/// `userContentController` add/install, and the `@MainActor` availability bridge;
/// only the JS text and the handler-name string live here.
public struct BrowserPasteAsPlainTextScript: Sendable, Equatable {
    /// Name of the WebKit message handler the focus tracker posts paste-target
    /// availability changes to. Interpolated into `focusTrackingBootstrapSource`
    /// and used by the app when registering the message handler.
    public static let focusMessageHandlerName = "cmuxPasteAsPlainTextFocus"

    /// JS source defining the shared `window.__cmuxPasteAsPlainTextHelpers`
    /// editable-target resolver. Interpolated into `focusTrackingBootstrapSource`.
    public static let sharedHelpersSource = """
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

    /// JS source injected at document start that installs the paste-target focus
    /// tracker and posts availability changes to `focusMessageHandlerName`.
    public static let focusTrackingBootstrapSource = """
    (() => {
      try {
        if (window.__cmuxPasteAsPlainTextFocusTrackerInstalled) return true;
        window.__cmuxPasteAsPlainTextFocusTrackerInstalled = true;

        const handler = (() => {
          try {
            return window.webkit?.messageHandlers?.\(focusMessageHandlerName) ?? null;
          } catch (_) {
            return null;
          }
        })();

        \(sharedHelpersSource)

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

    /// Side-effect-free synchronous preflight that reads
    /// `window.__cmuxCanPasteAsPlainTextIntoCurrentFocus` for the focused element.
    public static let pageCanAcceptPlainTextPreflightSource = """
    (() => {
        try {
            const fn = window.__cmuxCanPasteAsPlainTextIntoCurrentFocus;
            return typeof fn === 'function' ? !!fn() : false;
        } catch (_) {
            return false;
        }
    })();
    """
}

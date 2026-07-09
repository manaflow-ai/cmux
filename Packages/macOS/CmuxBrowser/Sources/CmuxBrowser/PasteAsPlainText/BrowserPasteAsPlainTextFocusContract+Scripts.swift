import Foundation

extension BrowserPasteAsPlainTextFocusContract {
    /// JavaScript injected at document start that tracks whether the focused page
    /// element can accept a plain-text paste and posts each change to the native
    /// ``messageHandlerName`` handler.
    ///
    /// Installs ``helpersScriptSource`` once, then publishes
    /// `window.__cmuxPasteAsPlainTextTargetAvailable` and posts `{ canPaste }`
    /// messages on `focusin`/`focusout`/`selectionchange`/`input`/`change`/
    /// `mousedown`/`beforeunload`. The app target injects this as a
    /// main-frame-only `WKUserScript`. Evaluates to `true` once installed.
    public var focusTrackingBootstrapScriptSource: String {
        """
    (() => {
      try {
        if (window.__cmuxPasteAsPlainTextFocusTrackerInstalled) return true;
        window.__cmuxPasteAsPlainTextFocusTrackerInstalled = true;

        const handler = (() => {
          try {
            return window.webkit?.messageHandlers?.\(messageHandlerName) ?? null;
          } catch (_) {
            return null;
          }
        })();

        \(Self.helpersScriptSource)

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
    }

    /// JavaScript that synchronously reports whether the page's currently focused
    /// element can accept a plain-text paste.
    ///
    /// Calls the `window.__cmuxCanPasteAsPlainTextIntoCurrentFocus` global that
    /// ``focusTrackingBootstrapScriptSource`` installs, returning `false` when the
    /// global is absent or throws. The app target evaluates this synchronously to
    /// decide whether to consume Cmd+Shift+V.
    public var focusedTargetQueryScriptSource: String {
        """
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

    /// Shared helper definitions installed once into `window.__cmuxPasteAsPlainTextHelpers`.
    ///
    /// Resolves the deepest active element across shadow roots and same-origin
    /// frames, classifies plain-text-capable controls, and exposes
    /// `canPasteAsPlainTextInto(el)`. Interpolated verbatim into
    /// ``focusTrackingBootstrapScriptSource``.
    private static let helpersScriptSource = """
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
}

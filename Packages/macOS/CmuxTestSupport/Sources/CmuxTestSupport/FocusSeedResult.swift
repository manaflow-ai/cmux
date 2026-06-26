#if DEBUG
public import Foundation

/// The parsed result of the goto-split focus-seed page script.
///
/// ``GotoSplitUITestRecorder/setupFocusedInput(panel:)`` runs a page script
/// (``seedScript``) inside a `BrowserPanel`'s `WKWebView` to inject two omnibar
/// fixture inputs, focus the primary one, and read back the page-side focus
/// state. The script source and the `[String: Any]` -> typed decode are pure
/// data with no AppKit/live-state coupling, so they live here; the recorder
/// keeps the `NSWindow`/`webView.convert` geometry math, the validation gate,
/// and the capture-file write app-side. The decoded fields mirror the legacy
/// inline `evaluateJavaScript` parse byte-for-byte (string fields default to
/// `""`, the two center coordinates default to `-1`, booleans default to
/// `false`).
public struct FocusSeedResult: Sendable {
    /// Whether the page reported the primary fixture input as `document.activeElement`.
    public let focused: Bool
    /// The primary fixture input element id (`""` when absent).
    public let inputId: String
    /// The secondary fixture input element id (`""` when absent).
    public let secondaryInputId: String
    /// The secondary input's viewport-normalized center x (`-1` when unavailable).
    public let secondaryCenterX: Double
    /// The secondary input's viewport-normalized center y (`-1` when unavailable).
    public let secondaryCenterY: Double
    /// The page's reported `document.activeElement` id (`""` when absent).
    public let activeId: String
    /// Whether the page-side address-bar focus tracker was installed.
    public let trackerInstalled: Bool
    /// The page-side tracked focus-state id (`""` when absent).
    public let trackedStateId: String
    /// The page's `document.readyState` string (`""` when absent).
    public let readyState: String

    /// Decodes the raw `evaluateJavaScript` result object into typed fields,
    /// reproducing the legacy inline cast-and-default behavior exactly.
    ///
    /// - Parameter jsResult: The `Any?` value handed to the
    ///   `evaluateJavaScript` completion handler.
    public init(jsResult: Any?) {
        let payload = jsResult as? [String: Any]
        self.focused = (payload?["focused"] as? Bool) ?? false
        self.inputId = (payload?["id"] as? String) ?? ""
        self.secondaryInputId = (payload?["secondaryId"] as? String) ?? ""
        self.secondaryCenterX = (payload?["secondaryCenterX"] as? NSNumber)?.doubleValue ?? -1
        self.secondaryCenterY = (payload?["secondaryCenterY"] as? NSNumber)?.doubleValue ?? -1
        self.activeId = (payload?["activeId"] as? String) ?? ""
        self.trackerInstalled = (payload?["trackerInstalled"] as? Bool) ?? false
        self.trackedStateId = (payload?["trackedStateId"] as? String) ?? ""
        self.readyState = (payload?["readyState"] as? String) ?? ""
    }

    public static let seedScript: String = """
        (() => {
          const snapshot = () => {
            const active = document.activeElement;
            return {
              focused: false,
              id: "",
              secondaryId: "",
              secondaryCenterX: -1,
              secondaryCenterY: -1,
              activeId: active && typeof active.id === "string" ? active.id : "",
              activeTag: active && active.tagName ? active.tagName.toLowerCase() : "",
              trackerInstalled: window.__cmuxAddressBarFocusTrackerInstalled === true,
              trackedStateId:
                window.__cmuxAddressBarFocusState &&
                typeof window.__cmuxAddressBarFocusState.id === "string"
                  ? window.__cmuxAddressBarFocusState.id
                  : "",
              readyState: String(document.readyState || "")
            };
          };
          const seed = () => {
            const ensureInput = (id, value) => {
              const existing = document.getElementById(id);
              const input = (existing && existing.tagName && existing.tagName.toLowerCase() === "input")
                ? existing
                : (() => {
                    const created = document.createElement("input");
                    created.id = id;
                    created.type = "text";
                    created.value = value;
                    return created;
                  })();
              input.autocapitalize = "off";
              input.autocomplete = "off";
              input.spellcheck = false;
              input.style.display = "block";
              input.style.width = "100%";
              input.style.margin = "0";
              input.style.padding = "8px 10px";
              input.style.border = "1px solid #5f6368";
              input.style.borderRadius = "6px";
              input.style.boxSizing = "border-box";
              input.style.fontSize = "14px";
              input.style.fontFamily = "system-ui, -apple-system, sans-serif";
              input.style.background = "white";
              input.style.color = "black";
              return input;
            };

            let container = document.getElementById("cmux-ui-test-focus-container");
            if (!container || !container.tagName || container.tagName.toLowerCase() !== "div") {
              container = document.createElement("div");
              container.id = "cmux-ui-test-focus-container";
              document.body.appendChild(container);
            }
            container.style.position = "fixed";
            container.style.left = "24px";
            container.style.top = "24px";
            container.style.width = "min(520px, calc(100vw - 48px))";
            container.style.display = "grid";
            container.style.rowGap = "12px";
            container.style.padding = "12px";
            container.style.background = "rgba(255,255,255,0.92)";
            container.style.border = "1px solid rgba(95,99,104,0.55)";
            container.style.borderRadius = "8px";
            container.style.boxShadow = "0 2px 10px rgba(0,0,0,0.2)";
            container.style.zIndex = "2147483647";

            const input = ensureInput("cmux-ui-test-focus-input", "cmux-ui-focus-primary");
            const secondaryInput = ensureInput("cmux-ui-test-focus-input-secondary", "cmux-ui-focus-secondary");
            if (input.parentElement !== container) {
              container.appendChild(input);
            }
            if (secondaryInput.parentElement !== container) {
              container.appendChild(secondaryInput);
            }

            input.focus({ preventScroll: true });
            if (typeof input.setSelectionRange === "function") {
              const end = input.value.length;
              input.setSelectionRange(end, end);
            }

            let trackedFocusId = input.getAttribute("data-cmux-addressbar-focus-id");
            if (!trackedFocusId) {
              trackedFocusId = "cmux-ui-test-focus-input-tracked";
              input.setAttribute("data-cmux-addressbar-focus-id", trackedFocusId);
            }
            const selectionStart = typeof input.selectionStart === "number" ? input.selectionStart : null;
            const selectionEnd = typeof input.selectionEnd === "number" ? input.selectionEnd : null;
            if (
              !window.__cmuxAddressBarFocusState ||
              typeof window.__cmuxAddressBarFocusState.id !== "string" ||
              window.__cmuxAddressBarFocusState.id !== trackedFocusId
            ) {
              window.__cmuxAddressBarFocusState = { id: trackedFocusId, selectionStart, selectionEnd };
            }

            const secondaryRect = secondaryInput.getBoundingClientRect();
            const viewportWidth = Math.max(Number(window.innerWidth) || 0, 1);
            const viewportHeight = Math.max(Number(window.innerHeight) || 0, 1);
            const secondaryCenterX = Math.min(
              0.98,
              Math.max(0.02, (secondaryRect.left + (secondaryRect.width / 2)) / viewportWidth)
            );
            const secondaryCenterY = Math.min(
              0.98,
              Math.max(0.02, (secondaryRect.top + (secondaryRect.height / 2)) / viewportHeight)
            );
            const active = document.activeElement;
            return {
              focused: active === input,
              id: input.id || "",
              secondaryId: secondaryInput.id || "",
              secondaryCenterX,
              secondaryCenterY,
              activeId: active && typeof active.id === "string" ? active.id : "",
              activeTag: active && active.tagName ? active.tagName.toLowerCase() : "",
              trackerInstalled: window.__cmuxAddressBarFocusTrackerInstalled === true,
              trackedStateId:
                window.__cmuxAddressBarFocusState &&
                typeof window.__cmuxAddressBarFocusState.id === "string"
                  ? window.__cmuxAddressBarFocusState.id
                  : "",
              readyState: String(document.readyState || "")
            };
          };
          const ready = () =>
            window.__cmuxAddressBarFocusTrackerInstalled === true &&
            String(document.readyState || "") === "complete";

          if (ready()) {
            try {
              return seed();
            } catch (_) {
              return snapshot();
            }
          }

          return new Promise((resolve) => {
            let finished = false;
            let observer = null;
            const cleanups = [];
            const finish = (value) => {
              if (finished) return;
              finished = true;
              if (observer) observer.disconnect();
              for (const cleanup of cleanups) {
                try { cleanup(); } catch (_) {}
              }
              resolve(value);
            };
            const maybeFinish = () => {
              if (!ready()) return;
              try {
                finish(seed());
              } catch (_) {
                finish(snapshot());
              }
            };
            const addListener = (target, eventName, options) => {
              if (!target || typeof target.addEventListener !== "function") return;
              const handler = () => maybeFinish();
              target.addEventListener(eventName, handler, options);
              cleanups.push(() => target.removeEventListener(eventName, handler, options));
            };
            try {
              observer = new MutationObserver(() => maybeFinish());
              observer.observe(document.documentElement || document, {
                childList: true,
                subtree: true,
                attributes: true,
                characterData: true
              });
            } catch (_) {}
            addListener(document, "readystatechange", true);
            addListener(window, "load", true);
            const timeoutId = window.setTimeout(() => finish(snapshot()), 4000);
            cleanups.push(() => window.clearTimeout(timeoutId));
            maybeFinish();
          });
        })();
        """
}
#endif
